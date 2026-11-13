#!/usr/bin/env bash
# =============================================================================
# ApplicationStop  (콘솔 이벤트 이름: ApplicationStop)
#
# 언제: 배포가 이 인스턴스에서 시작된 직후, 새 번들 다운로드 전에.
#       ALB 연동 그룹(lc-web)은 이 훅 "이전"에 BlockTraffic/AfterBlockTraffic 이 끝난다
#       (TG 에서 제외 + deregistration delay 동안 연결 비우기). 즉 여기서는 이미 트래픽이 없다.
# 무엇을 실행하나:
#       "이전에 성공한 리비전"의 아카이브에 있는 stop.sh (지금 배포 번들의 것이 아님!).
#       첫 배포에는 이전 리비전이 없어서 이 훅이 아예 실행되지 않는다(콘솔에 Skipped).
#       -> 그래서 stop.sh 가 고장난 리비전을 한 번 배포하면, "다음" 배포가 여기서 실패한다 (T4).
# 실패하면: 배포 Failed. 복구는 --ignore-application-stop-failures 로 재배포.
# 하는 일: lc-queue 는 supervisor 워커를 graceful 정지(SIGTERM -> 작업 마무리 -> 종료).
#          lc-web / lc-scheduler 는 멈출 것이 없다(php-fpm/nginx/cron 은 계속 켜 둔다).
# 규칙: 정지 작업 자체의 실패는 `|| true` 로 삼켜 배포를 막지 않는다.
#       단 FAULT=stop_fail 일 때만 일부러 실패한다.
# =============================================================================
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

log "ApplicationStop 시작 group=${DEPLOYMENT_GROUP_NAME:-?} deployment=${DEPLOYMENT_ID:-?} bundle=$BUNDLE_DIR sha=$(release_sha)"

# 알 수 없는 그룹이어도 정지 단계는 배포를 막지 않는다.
ROLE="$(role 2>/dev/null)" || ROLE="" # role() 은 실패 시 exit 하므로 `|| true` 를 서브셸 "안"에 두면 소용없다

case "$ROLE" in
  lc-queue)
    # supervisor 가 SIGTERM 을 보내고 stopwaitsecs(90초) 까지 기다린다.
    # 워커(bin/worker.php)는 진행 중인 작업을 끝낸 뒤 종료한다. (T14: worker.log 의 event=sigterm -> exit 확인)
    log "queue 워커 graceful 정지 (supervisorctl stop ${WORKER_PROGRAM}:*)"
    supervisorctl stop "${WORKER_PROGRAM}:*" || true
    ;;
  lc-web | lc-scheduler)
    log "$ROLE: 정지할 프로세스 없음 (php-fpm/nginx/cron 유지)"
    ;;
  *)
    log "알 수 없는 역할 '${DEPLOYMENT_GROUP_NAME:-}' -> 건너뜀"
    ;;
esac

# 의도적 고장 (T4): 이 리비전이 "이전 성공 리비전"이 되는 다음 배포 때 여기서 실패한다.
maybe_fail stop_fail

log "ApplicationStop 완료"
exit 0

#!/usr/bin/env bash
# =============================================================================
# ApplicationStart  (콘솔 이벤트 이름: ApplicationStart)
#
# 언제: AfterInstall 이 끝나 current 링크가 새 릴리스를 가리킨 뒤.
#       lc-web 은 아직 TG 에서 제외된 상태다(AllowTraffic 은 ValidateService 이후).
# 하는 일 (역할별):
#   공통     nginx 가 떠 있는지 확인, php-fpm reload
#            -> opcache.validate_timestamps=0 이라 reload 해야 새 코드가 반영된다 (ami/install.sh 가 설정).
#   lc-web       공통만.
#   lc-queue     supervisor 설정 재읽기 + 워커 graceful 재시작 (stop.sh 가 먼저 정지시켰고, 여기서 새 코드로 기동).
#                stopwaitsecs=90 이 가장 긴 작업(20초)보다 길어야 SIGKILL 없이 끝난다 (ami/install.sh 의 supervisor 설정).
#   lc-scheduler cron 파일(/etc/cron.d/lc-scheduler) 유지/복구 + cron 서비스 확인.
#                cron 은 항상 켜져 있고, 1분마다 current 의 heartbeat.php 를 부른다.
# 실패하면: 배포 Failed. 이 시점에 current 는 이미 새 릴리스를 가리키지만 php-fpm 은 reload 전일 수 있다.
#           자동 롤백이 켜져 있으면 이전 성공 리비전을 새 배포로 다시 설치한다.
# =============================================================================
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

ROLE="$(role)"
log "ApplicationStart 시작 role=$ROLE sha=$(release_sha) current=$(readlink -f "$CURRENT")"

# 의도적 고장: reload 전에 실패 (current 는 이미 새 릴리스, 서비스 프로세스는 아직 이전 상태)
maybe_fail start_fail

systemctl is-active --quiet nginx || systemctl start nginx
if systemctl is-active --quiet "$PHP_FPM_SERVICE"; then
  systemctl reload "$PHP_FPM_SERVICE"
  log "$PHP_FPM_SERVICE reload 완료"
else
  systemctl start "$PHP_FPM_SERVICE"
  log "$PHP_FPM_SERVICE 가 꺼져 있어서 start"
fi

case "$ROLE" in
  lc-web)
    : # 웹은 위의 reload 로 끝
    ;;
  lc-queue)
    systemctl is-active --quiet supervisor || systemctl start supervisor
    supervisorctl reread
    supervisorctl update
    # stop.sh 가 이미 정지시켰으면 단순 start, 첫 배포/정지 실패로 떠 있으면 SIGTERM -> 대기 -> start (graceful 재시작)
    supervisorctl restart "${WORKER_PROGRAM}:*"
    log "queue 워커 재시작 완료"
    ;;
  lc-scheduler)
    [ -f "$SCHEDULER_CRON_TEMPLATE" ] || die "cron 템플릿($SCHEDULER_CRON_TEMPLATE)이 없다. 골든 AMI/설치 스크립트(ami/install.sh) 확인"
    install -m 644 -o root -g root "$SCHEDULER_CRON_TEMPLATE" "$SCHEDULER_CRON"
    systemctl is-active --quiet cron || systemctl start cron
    log "scheduler cron 유지: $SCHEDULER_CRON"
    ;;
esac

log "ApplicationStart 완료"

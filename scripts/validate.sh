#!/usr/bin/env bash
# =============================================================================
# ValidateService  (콘솔 이벤트 이름: ValidateService)
#
# 언제: ApplicationStart 후. lc-web 은 이 훅이 성공해야 BeforeAllowTraffic -> AllowTraffic
#       (TG 재등록) 으로 넘어간다. 즉 여기서 실패하면 이 인스턴스는 트래픽을 받지 못한다.
# 하는 일:
#   1) curl -fs http://localhost/up 을 재시도 (php-fpm reload 직후 잠깐 실패할 수 있음)
#   2) /version 의 sha 가 이 번들의 REVISION SHA 와 같은지 확인
#      (다르면: current 링크가 안 바뀌었거나 php-fpm 이 옛 코드를 들고 있다는 뜻)
#   3) 역할별 앱 수준 확인: queue = 워커 RUNNING, scheduler = cron 파일 + cron 서비스
# 실패하면: 배포 Failed -> (자동 롤백 켜짐) 이전 성공 리비전 재배포.
#           lc-web 이 여러 대일 때 "마지막 인스턴스만" 실패하면 OneAtATime 은 전체를 Succeeded 로 본다 (T7).
# 고장 스위치: FAULT=validate_fail, 또는 FAULT=up500 (/up 이 500 -> 이 재시도가 소진되어 실패).
# =============================================================================
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

ROLE="$(role)"
EXPECTED="$(release_sha)"
ATTEMPTS="${VALIDATE_ATTEMPTS:-15}" # 15회 x 2초 = 약 30초 (appspec 훅 timeout 120초보다 훨씬 짧게)
log "ValidateService 시작 role=$ROLE expected_sha=$EXPECTED"

maybe_fail validate_fail

ok=0
reason="시도 안 함"
for i in $(seq 1 "$ATTEMPTS"); do
  if ! curl -fs --max-time 5 -o /dev/null http://localhost/up; then
    reason="/up 실패(HTTP 오류 또는 연결 불가)"
  else
    got="$(curl -fs --max-time 5 http://localhost/version | jq -r '.sha // empty' || true)"
    if [ "$got" = "$EXPECTED" ]; then
      ok=1
      break
    fi
    reason="SHA 불일치: 응답=${got:-<없음>} 기대=$EXPECTED"
  fi
  log "재시도 $i/$ATTEMPTS: $reason"
  sleep 2
done
[ "$ok" = 1 ] || die "ValidateService 실패: $reason"
log "/up 200 + SHA 일치 ($EXPECTED)"

case "$ROLE" in
  lc-queue)
    # 워커가 막 시작됐을 수 있으니 짧게 기다린다. (파이프+grep -q 는 pipefail 에서 SIGPIPE 로 오탐할 수 있어 변수에 담는다)
    st=""
    for _ in $(seq 1 10); do
      st="$(supervisorctl status "${WORKER_PROGRAM}:*" || true)"
      if grep -q RUNNING <<<"$st"; then
        break
      fi
      sleep 2
    done
    grep -q RUNNING <<<"$st" || die "queue 워커가 RUNNING 이 아니다: $st"
    log "queue 워커 RUNNING"
    ;;
  lc-scheduler)
    [ -f "$SCHEDULER_CRON" ] || die "cron 파일($SCHEDULER_CRON) 없음"
    systemctl is-active --quiet cron || die "cron 서비스가 꺼져 있다"
    log "scheduler cron OK"
    ;;
  lc-web) : ;;
esac

log "ValidateService 완료"

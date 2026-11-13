# shellcheck shell=bash
# shellcheck disable=SC2034  # 변수들은 이 파일을 source 하는 훅 스크립트에서 쓴다
# 훅 스크립트 공용 함수 (각 훅이 `source "$(dirname "$0")/lib.sh"` 로 읽는다).
#
# 중요(T4): ApplicationStop 은 "이전에 성공한 리비전"의 아카이브에 있는 scripts/ 를 실행한다.
#           그래서 이 파일도, FAULT 파일도 "그 스크립트가 들어 있던 번들"의 것을 쓴다.
#           (BUNDLE_DIR 를 현재 디렉터리가 아니라 이 파일 위치로 계산하는 이유)

set +x                                   # 비밀 출력 금지: 디버그 추적을 켜지 않는다
export AWS_DEFAULT_REGION=ap-northeast-2
export AWS_REGION=ap-northeast-2
export LC_ALL=C.UTF-8

APP_ROOT=/var/www
INCOMING="$APP_ROOT/_incoming"           # appspec 의 destination. CodeDeploy 가 여기에만 설치한다.
RELEASES="$APP_ROOT/releases"            # 릴리스 디렉터리: releases/<DEPLOYMENT_ID>
SHARED="$APP_ROOT/shared"                # 배포와 무관하게 유지: .env, storage
CURRENT="$APP_ROOT/current"              # 현재 릴리스를 가리키는 심볼릭 링크 (nginx root)
KEEP_RELEASES="${KEEP_RELEASES:-5}"      # 보관할 릴리스 수
SSM_PATH="/lcamtest/prd/"
PHP_FPM_SERVICE="php8.4-fpm"
WORKER_PROGRAM="lc-worker"               # supervisor program (ami/install.sh 가 설정 파일을 만든다)
SCHEDULER_CRON_TEMPLATE="/opt/lc/templates/lc-scheduler.cron"
SCHEDULER_CRON="/etc/cron.d/lc-scheduler"

# 이 파일이 들어 있는 번들의 루트 (scripts/ 의 부모)
BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

HOOK_NAME="${HOOK_NAME:-$(basename "$0" .sh)}"

log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$HOOK_NAME" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

# 배포 그룹 -> 역할. 같은 zip 을 3개 그룹에 쓰므로 훅이 이 값으로 분기한다.
role() {
  case "${DEPLOYMENT_GROUP_NAME:-}" in
    lc-web | lc-queue | lc-scheduler) printf '%s' "$DEPLOYMENT_GROUP_NAME" ;;
    *) die "알 수 없는 DEPLOYMENT_GROUP_NAME='${DEPLOYMENT_GROUP_NAME:-}' (lc-web|lc-queue|lc-scheduler 만 허용)" ;;
  esac
}

# KEY=VALUE 파일에서 값 하나 읽기 (없으면 기본값)
kv_get() { # file key default
  local v
  v="$(grep -E "^$2=" "$1" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '\r' || true)"
  printf '%s' "${v:-$3}"
}

release_sha() { kv_get "$BUNDLE_DIR/REVISION" SHA unknown; }

# IMDSv2 (토큰 -> 값). 실패하면 빈 문자열.
imds_get() { # path
  local token
  token="$(curl -fs --max-time 2 -X PUT 'http://169.254.169.254/latest/api/token' \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
  [ -n "$token" ] || return 0
  curl -fs --max-time 2 -H "X-aws-ec2-metadata-token: $token" \
    "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 고장 스위치 (번들 루트의 FAULT 파일)
#   FAULT=none | up500 | before_install_fail | after_install_fail | start_fail | validate_fail | stop_fail
#   FAULT_TARGET=all | instance:i-aaa,i-bbb | az:ap-northeast-2c | ssm
#     ssm = SSM 파라미터 /lcamtest/prd/FAULT_INSTANCE_IDS (쉼표 구분 instance-id) 에 이 인스턴스가 있으면 적용
#           -> 배포 순서를 본 뒤 "마지막 인스턴스만 실패"(T7)를 새 zip 없이 지정할 때 쓴다.
# 자세한 사용법: scripts/README.md
# ---------------------------------------------------------------------------
fault_applies() {
  local target iid az ids
  target="$(kv_get "$BUNDLE_DIR/FAULT" FAULT_TARGET all)"
  case "$target" in
    all) return 0 ;;
    instance:*)
      iid="$(imds_get instance-id)"
      [ -n "$iid" ] && [[ ",${target#instance:}," == *",$iid,"* ]]
      ;;
    az:*)
      az="$(imds_get placement/availability-zone)"
      [ -n "$az" ] && [ "$az" = "${target#az:}" ]
      ;;
    ssm)
      iid="$(imds_get instance-id)"
      ids="$(aws ssm get-parameter --name "${SSM_PATH}FAULT_INSTANCE_IDS" \
        --query Parameter.Value --output text 2>/dev/null || true)"
      [ -n "$iid" ] && [[ ",$ids," == *",$iid,"* ]]
      ;;
    *) return 1 ;; # 알 수 없는 대상이면 고장을 내지 않는다
  esac
}

# maybe_fail <스위치값>: FAULT 가 이 스위치이고 대상이 이 인스턴스면 일부러 실패시킨다.
maybe_fail() {
  local want="$1" have
  have="$(kv_get "$BUNDLE_DIR/FAULT" FAULT none)"
  if [ "$have" = "$want" ] && fault_applies; then
    log "FAULT 스위치 '$want' 발동 -> 의도적으로 실패(exit 1). 번들=$BUNDLE_DIR"
    exit 1
  fi
  return 0
}

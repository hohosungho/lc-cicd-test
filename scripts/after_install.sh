#!/usr/bin/env bash
# =============================================================================
# AfterInstall  (콘솔 이벤트 이름: AfterInstall)  <- 배포 로직의 핵심
#
# 언제: Install 이벤트(에이전트가 번들을 /var/www/_incoming 에 복사) 직후.
# 실행하는 스크립트: "이번 배포 번들"의 scripts/after_install.sh (이미 _incoming 에도 같은 파일이 있음).
#
# 순서(요구사항 §5-1):
#   1) SSM Parameter Store(/lcamtest/prd/*) -> shared/.env 생성 (권한 640)
#   2) _incoming -> releases/$DEPLOYMENT_ID 로 이동, shared/.env · shared/storage 링크
#   3) .env 가 "생긴 뒤에" (Laravel 이면) config:cache / route:cache / view:cache
#   4) current 심볼릭 링크 교체 (ln -sfn)  <- 이 순간에 새 버전이 서비스 대상이 된다
#   5) 오래된 릴리스 정리 (최근 KEEP_RELEASES 개만 보관)
#
# 왜 _incoming 에만 설치하나: CodeDeploy 는 "다음 배포 때 이전에 설치한 파일"을 지운다.
#   릴리스 파일을 에이전트의 설치 대상 밖(releases/)으로 옮겨 두면 이전 릴리스가 지워지지 않아
#   (a) 비상 수동 롤백(current 링크를 이전 릴리스로 되돌리기)이 가능하고 (b) 실행 중 코드가 사라지지 않는다.
#
# 멱등: 같은 배포 ID 로 다시 실행해도 안전하다 (이미 옮겼으면 이동을 건너뜀).
# 실패하면: current 는 아직 이전 릴리스를 가리킨다 -> 서비스는 이전 버전 그대로.
#           다만 releases/<이번 ID> 는 남는다. CodeDeploy 롤백은 스크립트가 만든 것을 되돌리지 않는다.
# =============================================================================
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

ROLE="$(role)"
DEPLOY_ID="${DEPLOYMENT_ID:?DEPLOYMENT_ID 환경변수 없음}"
RELEASE="$RELEASES/$DEPLOY_ID"
log "AfterInstall 시작 role=$ROLE release=$RELEASE sha=$(release_sha)"

# --- 1) .env 생성 ------------------------------------------------------------
# 값(비밀 포함)은 변수/파이프로만 흐르고 어디에도 출력하지 않는다. 키 이름만 로그에 남긴다.
# 파라미터 이름의 마지막 구간이 키가 된다: /lcamtest/prd/APP_KEY -> APP_KEY
# (하위 경로가 있어도 마지막 구간만 쓰므로 같은 이름이 있으면 충돌한다. 데모에서는 평평하게 만든다.)
build_env() ( # 서브셸: umask 077 이 스크립트 나머지에 번지지 않게 한다
  umask 077
  tmp="$(mktemp "$SHARED/.env.XXXXXX")"
  if ! aws ssm get-parameters-by-path --path "$SSM_PATH" --recursive --with-decryption --output json |
    jq -r '.Parameters[]
           | (.Name | split("/") | last) as $k
           | select($k | test("^[A-Za-z_][A-Za-z0-9_]*$"))
           | "\($k)=\(.Value | @json)"' >"$tmp"; then
    rm -f "$tmp"
    die "SSM get-parameters-by-path 실패 (인스턴스 역할의 ssm:GetParametersByPath / kms:Decrypt 권한, 경로 $SSM_PATH 확인)"
  fi
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    die "SSM $SSM_PATH 아래 파라미터가 없다 -> .env 를 만들 수 없음 (APP_NAME, APP_ENV, APP_KEY 를 SecureString 으로 만들어 두세요)"
  fi
  chown root:www-data "$tmp"
  chmod 640 "$tmp"
  mv -f "$tmp" "$SHARED/.env" # 같은 파일시스템 rename = 원자적. 읽는 쪽이 반쪽짜리 .env 를 보지 않는다.
  log ".env 생성 완료 (키 $(wc -l <"$SHARED/.env")개, 권한 $(stat -c '%a %U:%G' "$SHARED/.env"), 값은 출력하지 않음)"
)
mkdir -p "$SHARED/storage/logs"
build_env

# --- 2) 스테이징 -> 릴리스 이동, shared 링크 -----------------------------------
if [ -n "$(find "$INCOMING" -mindepth 1 -print -quit 2>/dev/null)" ]; then
  rm -rf "${RELEASE:?}"
  mkdir -p "$RELEASE"
  # 숨김 파일까지 모두 이동 (같은 파일시스템이므로 rename, 즉시 끝남)
  find "$INCOMING" -mindepth 1 -maxdepth 1 -exec mv -t "$RELEASE" {} +
  log "이동: $INCOMING -> $RELEASE"
elif [ -d "$RELEASE" ]; then
  log "이미 이동돼 있음(멱등 재실행): $RELEASE"
else
  die "스테이징($INCOMING)이 비어 있고 릴리스도 없다 (appspec files.destination 확인)"
fi
[ -f "$RELEASE/REVISION" ] || die "릴리스에 REVISION 파일이 없다"

# 권한: 코드는 root 소유 + 모두 읽기(php-fpm=www-data, 워커/cron=www-data 가 읽는다). storage 는 www-data 쓰기.
# (링크를 만들기 "전에" 처리한다: chown/chmod 가 링크 대상인 shared/ 를 건드리지 않게)
chown -R root:root "$RELEASE"
chmod -R go-w,a+rX "$RELEASE"

# shared 링크: Laravel 의 .env / storage 구조를 흉내 낸다 (릴리스가 바뀌어도 설정과 로그는 유지)
ln -sfn "$SHARED/.env" "$RELEASE/.env"
rm -rf "${RELEASE:?}/storage"
ln -sfn "$SHARED/storage" "$RELEASE/storage"
chown -R www-data:www-data "$SHARED/storage"

# --- 역할별 확인 (같은 zip 을 3개 그룹에 쓰므로 DEPLOYMENT_GROUP_NAME 으로 분기) ---------
case "$ROLE" in
  lc-web) : ;;                                  # 웹은 추가 작업 없음 (nginx + php-fpm)
  lc-queue) [ -f "$RELEASE/bin/worker.php" ] || die "bin/worker.php 없음" ;;
  lc-scheduler) [ -f "$RELEASE/bin/heartbeat.php" ] || die "bin/heartbeat.php 없음" ;;
esac

# --- 3) Laravel 캐시 (artisan 이 있을 때만; .env 가 생긴 뒤여야 한다) -------------------
# config:cache 는 그 시점의 .env 값을 캐시 파일에 굳힌다. .env 보다 먼저 돌리면 빈 설정이 굳는다.
if [ -f "$RELEASE/artisan" ]; then
  log "artisan 감지 -> config/route/view 캐시"
  (
    cd "$RELEASE"
    runuser -u www-data -- php artisan config:cache
    runuser -u www-data -- php artisan route:cache
    runuser -u www-data -- php artisan view:cache
  )
else
  log "artisan 없음(최소 PHP 앱) -> 캐시 단계 건너뜀"
fi

# 배포 메타데이터: 화면(/)과 /version 이 읽는다
{
  echo "DEPLOYMENT_ID=$DEPLOY_ID"
  echo "ROLE=$ROLE"
  echo "DEPLOYED_AT=$(date -Is)"
} >"$RELEASE/DEPLOY_INFO"
chmod 644 "$RELEASE/DEPLOY_INFO"

# 의도적 고장: current 교체 "전"에 실패 -> 이전 릴리스가 계속 서비스되는 것을 확인 (T3)
maybe_fail after_install_fail

# --- 4) current 교체 -----------------------------------------------------------
if [ -e "$CURRENT" ] && [ ! -L "$CURRENT" ]; then
  die "$CURRENT 가 심볼릭 링크가 아니다(실제 디렉터리). 수동으로 확인 필요"
fi
PREV="$(readlink -f "$CURRENT" 2>/dev/null || true)"
# ln -sfn 으로 임시 링크를 만든 뒤 mv -T 로 이름을 바꿔 끼운다 (rename 은 원자적 -> 교체 순간에도 current 가 비지 않음)
ln -sfn "$RELEASE" "$CURRENT.tmp"
mv -Tf "$CURRENT.tmp" "$CURRENT"
log "current 교체: ${PREV:-<없음>} -> $(readlink -f "$CURRENT")"
log "비상 수동 롤백: ln -sfn ${PREV:-<이전 릴리스>} $CURRENT && systemctl reload $PHP_FPM_SERVICE"

# --- 5) 오래된 릴리스 정리 ---------------------------------------------------------
# 최신 KEEP_RELEASES 개만 남긴다. 현재 릴리스와 직전 릴리스는 개수와 무관하게 지킨다.
find "$RELEASES" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -rn |
  awk -v keep="$KEEP_RELEASES" 'NR>keep {print $2}' |
  while read -r old; do
    case "$old" in
      "$RELEASE" | "${PREV:-/nonexistent}") continue ;;
    esac
    log "오래된 릴리스 삭제: $old"
    rm -rf "${old:?}"
  done

log "AfterInstall 완료"

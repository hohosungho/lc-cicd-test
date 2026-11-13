#!/usr/bin/env bash
# =============================================================================
# BeforeInstall  (콘솔 이벤트 이름: BeforeInstall)
#
# 언제: 새 번들 다운로드(DownloadBundle) 후, 에이전트가 파일을 복사(Install)하기 전에.
# 실행하는 스크립트: "이번 배포 번들"의 scripts/before_install.sh.
# 하는 일:
#   - 배포 그룹 이름 검증(역할 분기의 전제)
#   - /var/www 디렉터리 구조 보장 (AMI 에 이미 있지만 멱등하게 다시 확인)
#   - 스테이징 /var/www/_incoming 을 비운다: Install 이벤트가 여기에만 파일을 복사한다.
#     (file_exists_behavior OVERWRITE 이므로 남은 파일이 있어도 덮어쓰지만, 이전 배포의 잔여물이 섞이지 않게 비운다)
# 실패하면: 배포 Failed -> 자동 롤백 켜져 있으면 "마지막 성공 리비전"을 새 배포로 재배포.
#           아직 서비스 중인 current 는 건드리지 않았으므로 이전 버전이 계속 응답한다.
# =============================================================================
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

ROLE="$(role)"
log "BeforeInstall 시작 role=$ROLE deployment=${DEPLOYMENT_ID:-?} sha=$(release_sha)"

# 디렉터리 구조 (멱등)
mkdir -p "$INCOMING" "$RELEASES" "$SHARED/storage/logs"
chown -R www-data:www-data "$SHARED/storage"
chmod 755 "$APP_ROOT"

# 스테이징 비우기. 디렉터리 자체는 남기고 내용만 지운다(숨김 파일 포함).
find "$INCOMING" -mindepth 1 -delete
log "스테이징 비움: $INCOMING"

# 의도적 고장: 모든 준비가 끝난 뒤 실패 -> "BeforeInstall 에서 실패해도 이전 상태 그대로"를 보여 준다.
maybe_fail before_install_fail

log "BeforeInstall 완료"

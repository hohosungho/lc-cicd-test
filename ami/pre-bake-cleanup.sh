#!/usr/bin/env bash
# =============================================================================
# 골든 AMI 굽기 직전 정리 스크립트 — "이미지로 만들 그 인스턴스"에서 root 로 실행하는 마지막 작업.
#
# 사용:  sudo bash pre-bake-cleanup.sh --yes
#   실행 직후 로그아웃하고 곧바로 콘솔에서 [작업 > 이미지 및 템플릿 > 이미지 생성] 을 한다.
#   (이 인스턴스는 더 이상 서비스용이 아니다. 실행 중인 ASG 인스턴스나 운영 서버에서 돌리지 말 것!)
#
# 하는 일 (요구사항 §3: "코드와 .env 는 넣지 않는다. 굽기 전 에이전트 정지 후 정리")
#   1) 서비스 정지: CodeDeploy 에이전트, 워커, nginx, php-fpm
#   2) 앱 흔적 제거: current/releases/_incoming/.env/storage 로그 (단독 Web 에 한 번 배포한 뒤 굽는 순서라서 필요)
#   3) CodeDeploy 에이전트 상태 제거: deployment-root(이전 배포 아카이브/지시서), 에이전트 로그
#      -> 새 인스턴스의 에이전트가 "이 인스턴스에서 배포한 적 없음" 상태로 시작한다
#         (첫 배포에서 ApplicationStop 이 건너뛰어지고, 옛 아카이브가 남지 않는다).
#   4) 인스턴스 고유 파일: SSH 호스트 키, authorized_keys, machine-id, cloud-init 상태, 셸 히스토리, 로그
# 에이전트는 enable 상태로 남긴다 -> 새 인스턴스가 부팅하면 자동 시작한다.
#   (초기화 스크립트가 길어질 때만 install.sh 를 AGENT_ENABLE_ON_BOOT=0 으로 실행하고 마지막에 직접 start. 근거는 install.sh 상단 troubleshooting 링크)
#
# 미검증: 에이전트 2.x 의 on-disk layout 은 문서상 1.x 와 같다고 되어 있으나(codedeploy-agent.html 버전 이력 2.0.0),
#         경로(/opt/codedeploy-agent/deployment-root, /var/log/aws/codedeploy-agent)는 인스턴스에서 직접 확인할 것.
#         경로가 다르면 아래 3)번 블록만 고치면 된다.
# =============================================================================
set -euo pipefail
unset HISTFILE

[ "$(id -u)" -eq 0 ] || { echo "root 로 실행하세요" >&2; exit 1; }
if [ "${1:-}" != "--yes" ]; then
  cat >&2 <<'EOF'
이 스크립트는 이 인스턴스의 앱 코드, .env, 로그, SSH 키, cloud-init 상태를 지운다.
이미지(AMI)를 만들 인스턴스에서만 실행하세요. 계속하려면:  sudo bash pre-bake-cleanup.sh --yes
EOF
  exit 2
fi

echo "[1/4] 서비스 정지"
systemctl stop codedeploy-agent || true
supervisorctl stop all || true
systemctl stop nginx php8.4-fpm || true
rm -f /etc/cron.d/lc-scheduler

echo "[2/4] 앱 흔적 제거 (코드/.env 는 AMI 에 넣지 않는다)"
rm -rf /var/www/current /var/www/current.tmp
find /var/www/releases /var/www/_incoming -mindepth 1 -delete 2>/dev/null || true
rm -f /var/www/shared/.env /var/www/shared/.env.* /var/www/shared/FAULT_UP_500
find /var/www/shared/storage -mindepth 1 -delete 2>/dev/null || true
install -d -m 755 -o www-data -g www-data /var/www/shared/storage/logs
rm -f /var/log/lc/* /var/log/nginx/lc-access.log

echo "[3/4] CodeDeploy 에이전트 상태 제거"
find /opt/codedeploy-agent/deployment-root -mindepth 1 -delete 2>/dev/null || true
find /var/log/aws/codedeploy-agent -type f -delete 2>/dev/null || true

echo "[4/4] 인스턴스 고유 파일 제거"
rm -f /etc/ssh/ssh_host_* # cloud-init 이 새 인스턴스 첫 부팅 때 다시 만든다
rm -f /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys
rm -f /root/.bash_history /home/*/.bash_history
truncate -s 0 /etc/machine-id # systemd 가 새 인스턴스에서 새로 생성 (/var/lib/dbus/machine-id 는 이 파일의 링크)
cloud-init clean --logs --seed # 다음 부팅을 "첫 부팅"으로 만든다 (user-data 재실행 가능)
journalctl --rotate >/dev/null 2>&1 || true
journalctl --vacuum-time=1s >/dev/null 2>&1 || true
find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' \) -delete 2>/dev/null || true
find /var/log -type f -exec truncate -s 0 {} + 2>/dev/null || true
apt-get clean
rm -rf /tmp/* /var/tmp/* 2>/dev/null || true
sync

echo "정리 끝. 지금 바로 로그아웃하고 AMI 를 만드세요 (이름: lc-web-golden-<yyyymmdd>)."
echo "이 시점 이후 이 인스턴스에 다시 들어가 작업하면 로그/히스토리가 다시 생깁니다."

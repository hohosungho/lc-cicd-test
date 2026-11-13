#!/usr/bin/env bash
# =============================================================================
# lc 런타임 설치 스크립트 — 골든 AMI 용 / 단독 Web·Queue·Scheduler 인스턴스 user-data 용 (같은 파일)
#
# 실행: root, Ubuntu Server 24.04 (x86_64 또는 aarch64), 인터넷 아웃바운드 필요(public 서브넷+퍼블릭 IP).
#   - EC2 콘솔 user-data 에 이 파일 내용을 그대로 붙여넣는다 (16KB 제한; 이 파일은 그 안쪽).
#   - 또는 Session Manager 로 접속해서 `sudo bash install.sh`.
#   로그: /var/log/lc-install.log (user-data 로 돌 때는 /var/log/cloud-init-output.log 에도 남음)
# 멱등: 다시 실행해도 안전하다 (설정 파일은 덮어쓰고, 이미 설치된 패키지는 건너뜀).
#
# 담는 것 : nginx, php8.4-fpm/cli/opcache, supervisor, cron, AWS CLI v2, CodeDeploy 에이전트(2.0.x 이상),
#           nginx/php/supervisor/cron 설정, /var/www 디렉터리 구조.
# 담지 않는 것 : 앱 코드, .env  (코드는 CodeDeploy, .env 는 after_install.sh 가 생성)
#
# 역할(Web/Queue/Scheduler)은 여기서 정하지 않는다. 인스턴스가 속한 CodeDeploy 배포 그룹이 정한다.
#   - supervisor 워커 설정은 autostart=false 로 깔려 있어 Web 에서는 돌지 않고, lc-queue 배포(start.sh)가 켠다.
#   - scheduler cron 은 /opt/lc/templates 에만 두고, lc-scheduler 배포(start.sh)가 /etc/cron.d 에 설치한다.
#   => 같은 AMI 한 장으로 세 역할을 모두 띄울 수 있다.
#
# 출처(이 스크립트를 쓸 때 공식 문서에서 확인한 내용):
#   * 에이전트 설치 경로 .../latestv2/install (2.0.x 이상), `sudo ./install auto`, 확인은 systemctl status codedeploy-agent
#     https://docs.aws.amazon.com/codedeploy/latest/userguide/codedeploy-agent-operations-install-ubuntu.html
#   * Ubuntu 24.04 는 에이전트 2.0.x 이상에서 테스트됨, 에이전트는 systemd 로 관리, 아웃바운드 HTTPS 443 사용
#     https://docs.aws.amazon.com/codedeploy/latest/userguide/codedeploy-agent.html
#   * AMI 에 에이전트를 넣을 때는 Stopped 상태로 굽고 인스턴스 초기화 스크립트의 "마지막"에 시작시키라는 권고
#     https://docs.aws.amazon.com/codedeploy/latest/userguide/troubleshooting-auto-scaling.html
#   * 미검증: PHP 8.4 는 Ubuntu 24.04 기본 저장소에 없어 ppa:ondrej/php 를 쓴다(인스턴스에서 실제 설치로만 확인 가능).
#     에이전트 2.x 패키지 이름이 `codedeploy-agent` 인지, 상태/로그 경로가 1.x 와 같은지(문서의 "on-disk layout unchanged"
#     외 직접 확인 없음)는 설치 후 인스턴스에서 확인할 것.
# =============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

REGION="${AWS_REGION:-ap-northeast-2}"
PHP_V="${PHP_V:-8.4}"
# 1 = 부팅 시 에이전트 자동 시작(기본). 초기화 스크립트가 길면 0 으로 하고 마지막에 직접 start (위 troubleshooting 문서 참고)
AGENT_ENABLE_ON_BOOT="${AGENT_ENABLE_ON_BOOT:-1}"

[ "$(id -u)" -eq 0 ] || { echo "root 로 실행하세요" >&2; exit 1; }
exec > >(tee -a /var/log/lc-install.log) 2>&1
echo "=== lc install 시작 $(date -Is) region=$REGION php=$PHP_V ==="

# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = ubuntu ] && [ "${VERSION_ID:-}" = "24.04" ] || echo "경고: Ubuntu 24.04 가 아니다 (${PRETTY_NAME:-?}). 계속 진행"

# --- 1) 기본 패키지 ---------------------------------------------------------------
apt-get update -y
apt-get install -y ca-certificates curl wget unzip jq cron gnupg software-properties-common nginx supervisor

# --- 2) PHP 8.4 (ondrej/php PPA) ----------------------------------------------------
if ! dpkg -s "php${PHP_V}-fpm" >/dev/null 2>&1; then
  add-apt-repository -y ppa:ondrej/php
  apt-get update -y
fi
apt-get install -y "php${PHP_V}-cli" "php${PHP_V}-fpm" "php${PHP_V}-opcache" \
  "php${PHP_V}-mbstring" "php${PHP_V}-xml" "php${PHP_V}-curl"

# --- 3) AWS CLI v2 (Ubuntu 24.04 에는 apt 의 awscli 패키지가 없다) --------------------------
if ! aws --version 2>/dev/null | grep -q '^aws-cli/2'; then
  tmp="$(mktemp -d)"
  curl -fsS "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "$tmp/awscliv2.zip"
  unzip -q "$tmp/awscliv2.zip" -d "$tmp"
  "$tmp/aws/install" --update
  rm -rf "$tmp"
fi

# --- 4) CodeDeploy 에이전트 v2 -----------------------------------------------------------
if ! systemctl cat codedeploy-agent >/dev/null 2>&1; then
  tmp="$(mktemp -d)"
  wget -q "https://aws-codedeploy-${REGION}.s3.${REGION}.amazonaws.com/latestv2/install" -O "$tmp/install"
  chmod +x "$tmp/install"
  "$tmp/install" auto # 특정 버전: "$tmp/install" auto -v releases/codedeploy-agent_<ver>_<amd64|arm64>.deb
  rm -rf "$tmp"
fi
agent_ver="$(dpkg-query -W -f='${Version}' codedeploy-agent 2>/dev/null || echo unknown)"
echo "CodeDeploy 에이전트 패키지 버전: $agent_ver"
case "$agent_ver" in 2.*) ;; *) echo "경고: 에이전트 버전이 2.x 로 확인되지 않음($agent_ver). 요구사항은 2.0.x 이상" ;; esac

# --- 5) 디렉터리 구조 (코드/.env 는 넣지 않는다) ----------------------------------------------
install -d -m 755 /var/www /var/www/_incoming /var/www/releases /opt/lc/templates
install -d -m 755 -o www-data -g www-data /var/www/shared/storage /var/www/shared/storage/logs /var/log/lc

# --- 6) nginx: 모든 요청을 current/public 의 front controller(index.php)로 -----------------------
rm -f /etc/nginx/sites-enabled/default
cat >/etc/nginx/conf.d/lc.conf <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    server_tokens off;
    # current 는 심볼릭 링크. $realpath_root 로 실제 릴리스 경로를 풀어 php-fpm 에 넘긴다(교체 직후 옛/새 경로 혼재 방지).
    root /var/www/current/public;
    access_log /var/log/nginx/lc-access.log;
    location / {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php8.4-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $realpath_root/index.php;
        fastcgi_param DOCUMENT_ROOT $realpath_root;
        fastcgi_read_timeout 30s;
    }
}
EOF
sed -i "s#php8\.4-fpm\.sock#php${PHP_V}-fpm.sock#" /etc/nginx/conf.d/lc.conf

# --- 7) PHP: opcache 는 타임스탬프 검사 끔 -> 배포 시 start.sh 의 php-fpm reload 가 꼭 필요하다 -------
cat >"/etc/php/${PHP_V}/fpm/conf.d/90-lc.ini" <<'EOF'
expose_php=Off
date.timezone=Asia/Seoul
opcache.enable=1
opcache.validate_timestamps=0
EOF
printf 'date.timezone=Asia/Seoul\n' >"/etc/php/${PHP_V}/cli/conf.d/90-lc.ini"

# --- 8) supervisor: 더미 Queue 워커 (autostart=false; lc-queue 배포가 켠다) ----------------------
cat >/etc/supervisor/conf.d/lc-worker.conf <<'EOF'
[program:lc-worker]
command=/usr/bin/php /var/www/current/bin/worker.php
user=www-data
numprocs=1
autostart=false
autorestart=true
startsecs=5
stopsignal=TERM
; 정지 시 SIGTERM 후 최대 90초 기다린 뒤 SIGKILL. 가장 긴 작업(worker.php 기본 20초)보다 길게.
; 단, stop.sh 훅 timeout(appspec 120초)보다는 짧게.
stopwaitsecs=90
redirect_stderr=true
stdout_logfile=/var/log/lc/worker-supervisor.log
stdout_logfile_maxbytes=5MB
stdout_logfile_backups=2
EOF

# --- 9) Scheduler cron 템플릿 (설치는 lc-scheduler 배포의 start.sh 가 /etc/cron.d 로) ----------------
cat >/opt/lc/templates/lc-scheduler.cron <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * www-data /usr/bin/php /var/www/current/bin/heartbeat.php scheduler >> /var/log/lc/scheduler-cron.log 2>&1
EOF
chmod 644 /opt/lc/templates/lc-scheduler.cron

cat >/etc/logrotate.d/lc <<'EOF'
/var/www/shared/storage/logs/*.log /var/log/lc/*.log {
    daily
    rotate 3
    compress
    missingok
    notifempty
    copytruncate
}
EOF

# --- 10) 서비스 기동/활성화 + 설정 검사 ------------------------------------------------------------
nginx -t
"php-fpm${PHP_V}" -t
systemctl enable --now nginx "php${PHP_V}-fpm" supervisor cron
systemctl reload nginx
systemctl restart "php${PHP_V}-fpm"
supervisorctl reread >/dev/null
supervisorctl update >/dev/null

if [ "$AGENT_ENABLE_ON_BOOT" = 1 ]; then
  systemctl enable --now codedeploy-agent
else
  systemctl disable codedeploy-agent
  echo "에이전트 자동 시작 꺼짐: 초기화가 끝난 뒤 'systemctl start codedeploy-agent' 를 직접 실행해야 한다"
fi

echo "=== 요약 ==="
nginx -v 2>&1
"php${PHP_V}" -v | head -n1
supervisord --version | sed 's/^/supervisor /'
aws --version
echo "codedeploy-agent: $(systemctl is-active codedeploy-agent || true) ($agent_ver)"
snap list amazon-ssm-agent 2>/dev/null | tail -n +2 || echo "참고: snap amazon-ssm-agent 가 보이지 않음 (Session Manager 접속 가능 여부 확인)"
echo "=== lc install 완료 $(date -Is) ==="

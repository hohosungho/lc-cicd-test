# ami/ — 골든 AMI 만들기

골든 AMI 에는 런타임(nginx, php8.4-fpm, supervisor, cron, AWS CLI v2, CodeDeploy 에이전트 2.x)과 설정 파일만 넣는다. **코드와 `.env` 는 넣지 않는다.** 코드는 CodeDeploy 가 배포한다. 이 문서는 콘솔 기준 절차이고, AWS 리소스는 사용자가 직접 만든다.

| 파일 | 용도 |
|---|---|
| `install.sh` | 인스턴스 안에서 root 로 실행하는 설치 스크립트. AMI 용과 단독 Web/Queue/Scheduler user-data 용이 같은 파일이다 (약 9KB, user-data 16KB 제한 이내) |
| `pre-bake-cleanup.sh` | AMI 를 굽기 직전에 실행하는 정리 스크립트 |

`install.sh` 는 역할을 정하지 않는다. 역할은 인스턴스가 속한 CodeDeploy 배포 그룹이 정한다. 워커는 `autostart=false` 로 설치되고, scheduler cron 은 템플릿(`/opt/lc/templates/lc-scheduler.cron`)으로만 놓인다. 그래서 같은 AMI 로 Web, Queue, Scheduler 를 모두 띄울 수 있다.

## 절차 (요구사항 §6-1: 단독 Web 에서 첫 배포 성공 → 골든 AMI)

### 1. 단독 Web 인스턴스 시작 (EC2 > 인스턴스 > 인스턴스 시작)

| 항목 | 값 |
|---|---|
| 이름 / 태그 | `Name=lcamtest-web`, `lc-deploy=web-standalone`, `Project=lcamtest`, `Owner=sungho`, `Ephemeral=true` |
| AMI | Ubuntu Server 24.04 LTS (Canonical 공식, 시작 시점의 최신) |
| 인스턴스 유형 | t3.small (또는 t4g.small, 이 경우 arm64) |
| 키 페어 | 없음 (SSH 안 씀) |
| 네트워크 | lc VPC 의 public 서브넷, 퍼블릭 IP 자동 할당 **활성화**, 보안 그룹 `lc-ec2-sg` (인바운드: `lc-alb-sg` 에서 80 만) |
| 스토리지 | gp3 8~10GiB, **암호화** |
| IAM 인스턴스 프로파일 | `lc-ec2-profile` |
| 고급 > 메타데이터 | IMDSv2 **필수**, 응답 홉 제한 **2** |
| 고급 > 사용자 데이터 | `install.sh` 내용 전체를 붙여넣기 (첫 줄 `#!/usr/bin/env bash` 포함) |

### 2. 설치 확인 (Systems Manager > Fleet Manager 또는 EC2 > 연결 > 세션 관리자)

설치는 몇 분 걸린다. 끝났는지 확인:

```bash
sudo tail -n 20 /var/log/lc-install.log        # 마지막 줄: "=== lc install 완료 ..."
systemctl is-active nginx php8.4-fpm supervisor cron codedeploy-agent
dpkg-query -W -f='${Version}\n' codedeploy-agent   # 2.x 인지 확인
aws --version                                       # aws-cli/2.x
ls /var/www                                         # _incoming  releases  shared  (current 없음)
```

실패하면 `/var/log/cloud-init-output.log` 와 `/var/log/lc-install.log` 를 본다. 스크립트는 다시 실행해도 안전하다 (`sudo bash install.sh`).

### 3. 첫 배포 (CodeDeploy)

이 인스턴스를 태그 기반 배포 그룹(`lc-web`, 태그 `lc-deploy=web-standalone`)에 넣고 GitHub Actions 로 배포한다. `Succeeded` 를 확인하고 인스턴스에서:

```bash
curl -s localhost/version
ls -l /var/www/current /var/www/releases
```

### 4. 굽기 직전 정리

정리 스크립트는 배포된 번들 안에 들어 있다 (`ami/pre-bake-cleanup.sh`). 지우는 대상이 `/var/www/current` 라서 `/tmp` 로 복사해서 실행한다.

```bash
sudo cp /var/www/current/ami/pre-bake-cleanup.sh /tmp/pre-bake-cleanup.sh
sudo bash /tmp/pre-bake-cleanup.sh --yes
```

이 스크립트는 에이전트를 정지하고 `deployment-root`, 에이전트 로그, 앱 코드(`current`, `releases`), `.env`, SSH 호스트 키, machine-id, cloud-init 상태, 셸 히스토리를 지운다. 실행 후 세션을 닫고 바로 다음으로 넘어간다.

### 5. AMI 생성 (EC2 > 인스턴스 > 작업 > 이미지 및 템플릿 > 이미지 생성)

| 항목 | 값 |
|---|---|
| 이미지 이름 | `lc-web-golden-<yyyymmdd>` (예: `lc-web-golden-20261113`) |
| 재부팅 안 함 | **체크하지 않는다** (재부팅해야 파일시스템이 일관된다) |
| 태그 | 이미지·스냅샷 모두 `Project=lcamtest`, `Owner=sungho`, `Ephemeral=true` |

EC2 > AMI 에서 상태가 `사용 가능` 이 될 때까지 기다린다.

### 6. 굽기 검증

AMI 로 인스턴스를 **사용자 데이터 없이** 하나 띄운다 (설정은 1번과 같고 AMI 만 다름. 태그 `Name=lcamtest-ami-check`).

```bash
systemctl is-active nginx php8.4-fpm supervisor cron codedeploy-agent   # 모두 active
ls /var/www ; ls /var/www/releases /var/www/shared                      # 코드·.env 없음
sudo ls /opt/codedeploy-agent/deployment-root                           # 비어 있음 (확인 필요: 2.x 경로)
```

그 뒤 launch template(`lc-web-lt`)에 이 AMI 를 지정하고 ASG 에서 launch deployment 가 성공하는지 확인한다 (요구사항 §3 마지막 항목, §6-4). 검증에 쓴 확인용 인스턴스는 종료한다.

## 단독 Queue / Scheduler 인스턴스

두 가지 방법이 있다.

- 골든 AMI 로 시작 (user-data 없음). 가장 빠르다.
- 순정 Ubuntu 24.04 로 시작하고 user-data 에 `install.sh` 를 붙여넣기. AMI 없이도 같은 결과.

태그 `Name=lcamtest-queue` / `Name=lcamtest-scheduler` 를 붙이고, 각 태그를 필터로 하는 배포 그룹(`lc-queue`, `lc-scheduler`)에 배포한다. 같은 인스턴스 프로파일·보안 그룹을 쓴다.

## 참고 (공식 문서)

- 에이전트 설치(Ubuntu, `latestv2/install`): https://docs.aws.amazon.com/codedeploy/latest/userguide/codedeploy-agent-operations-install-ubuntu.html
- 지원 OS(Ubuntu 24.04 는 2.0.x 이상에서 테스트됨): https://docs.aws.amazon.com/codedeploy/latest/userguide/codedeploy-agent.html
- AMI 에 에이전트를 넣을 때 주의: https://docs.aws.amazon.com/codedeploy/latest/userguide/troubleshooting-auto-scaling.html

## 미검증 항목

스크립트를 AWS 인스턴스에서 실행해 보지 않았다 (이 저장소 작업은 AWS 에 명령을 내리지 않는다). 처음 돌릴 때 특히 확인할 곳:

- `ppa:ondrej/php` 로 PHP 8.4 설치
- 에이전트 2.x 패키지 이름(`codedeploy-agent`)과 `deployment-root` / 로그 경로
- `pre-bake-cleanup.sh` 이후 새 인스턴스의 cloud-init 과 SSH 호스트 키 재생성 (SSH 는 쓰지 않으므로 영향 작음)

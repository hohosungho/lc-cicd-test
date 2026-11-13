# scripts/ — CodeDeploy 훅과 고장 스위치

같은 zip 을 `lc-web`, `lc-queue`, `lc-scheduler` 3개 배포 그룹에 쓴다. 훅이 `DEPLOYMENT_GROUP_NAME` 으로 역할을 나눈다. 훅 안에 이벤트 시점과 동작 설명이 주석으로 있다. 여기에는 요약만 둔다.

## 배포 한 번의 흐름 (인스턴스 한 대 기준)

| 순서 | 콘솔 이벤트 | 누가 | 이 데모에서 일어나는 일 |
|---|---|---|---|
| 1 | BeforeBlockTraffic / BlockTraffic / AfterBlockTraffic (lc-web 만) | CodeDeploy | TG 에서 인스턴스 제외, deregistration delay 만큼 연결 비우기 |
| 2 | ApplicationStop | **이전 성공 리비전**의 `stop.sh` | queue: 워커 graceful 정지. 첫 배포는 Skipped |
| 3 | DownloadBundle | 에이전트 | S3 zip 다운로드·압축 해제 |
| 4 | BeforeInstall | `before_install.sh` | 역할 검증, `/var/www/_incoming` 비우기 |
| 5 | Install | 에이전트 | zip 루트 전체를 `/var/www/_incoming` 으로 복사 |
| 6 | AfterInstall | `after_install.sh` | SSM → `shared/.env`, `_incoming` → `releases/<DEPLOYMENT_ID>`, shared 링크, **current 교체**, 오래된 릴리스 정리 |
| 7 | ApplicationStart | `start.sh` | php-fpm reload. queue: 워커 재시작. scheduler: cron 유지 |
| 8 | ValidateService | `validate.sh` | `/up` 200 재시도 + `/version` 의 SHA == REVISION SHA |
| 9 | BeforeAllowTraffic / AllowTraffic / AfterAllowTraffic (lc-web 만) | CodeDeploy | TG 재등록, healthy 가 될 때까지 대기(최대 1시간) |

서버의 디렉터리:

```
/var/www/_incoming/          에이전트가 설치하는 스테이징 (배포마다 비움)
/var/www/releases/<id>/      릴리스 (id = DEPLOYMENT_ID, 최근 5개 보관)
/var/www/shared/.env         SSM 에서 만든 설정 (640 root:www-data)
/var/www/shared/storage/     로그 등 (heartbeat.log, worker.log)
/var/www/current -> releases/<id>   nginx root = current/public
```

## 고장 스위치

번들 루트의 `FAULT` 파일이 정한다. GitHub Actions 의 **Run workflow** 입력(`fault`, `fault_target`)이 이 파일을 만든다. push 로 배포하면 `FAULT=none`, `FAULT_TARGET=all`.

```
FAULT=none
FAULT_TARGET=all
```

### FAULT 값

| 값 | 실패하는 곳 | 실패 직후 서버 상태 | 시험 |
|---|---|---|---|
| `none` | 없음 | 정상 | T1 |
| `up500` | `/up` 이 500. ValidateService 가 재시도(약 30초) 끝에 실패. 배포 후 ALB 헬스체크도 실패 | 새 코드가 올라가 있고 TG 에는 재등록되지 않음 | T2, T12 |
| `before_install_fail` | BeforeInstall 끝 | 아무것도 안 바뀜 (`current` 는 이전 릴리스) | T3 |
| `after_install_fail` | AfterInstall, `current` 교체 직전 | `releases/<id>` 와 새 `.env` 는 생겼지만 `current` 는 이전 릴리스 | T3 |
| `start_fail` | ApplicationStart 첫머리 | `current` 는 새 릴리스, php-fpm/워커는 아직 이전 상태 | T3 |
| `validate_fail` | ValidateService 첫머리 | 새 릴리스가 `current`, TG 재등록 안 됨 | T2, T3 |
| `stop_fail` | **이 리비전의 `stop.sh`**. 이 리비전 배포는 성공하고, **다음 배포**의 ApplicationStop 이 실패 | 다음 배포가 Failed | T4 |

### FAULT_TARGET (어느 인스턴스에서 실패하나)

| 값 | 의미 |
|---|---|
| `all` | 모든 대상 인스턴스 (기본) |
| `instance:i-aaa,i-bbb` | 나열한 instance-id 에서만 |
| `az:ap-northeast-2c` | 그 AZ 의 인스턴스에서만 |
| `ssm` | SSM 파라미터 `/lcamtest/prd/FAULT_INSTANCE_IDS` (쉼표 구분 instance-id)에 있는 인스턴스에서만 |

T7 "마지막 인스턴스만 실패" 방법:
1. 먼저 정상 배포로 두 대가 같은 리비전인지 확인한다.
2. 이번 배포의 처리 순서는 미리 알 수 없다. 배포를 시작한 뒤 `aws deploy list-deployment-targets` 로 순서를 확인하거나, 순서를 알 수 없으면 `ssm` 모드를 쓴다.
3. `ssm` 모드: 파라미터 `/lcamtest/prd/FAULT_INSTANCE_IDS`(String)에 대상 instance-id 를 넣고 `fault=validate_fail`, `fault_target=ssm` 으로 배포한다. 훅이 실행 시점에 이 값을 읽으므로 배포 도중에도 바꿀 수 있다. 시험이 끝나면 파라미터를 지운다.
4. 인스턴스 태그로 지정하는 방식은 쓰지 않는다. 훅에서 태그를 읽으려면 `ec2:DescribeTags` 권한(또는 IMDS 태그 노출 설정)이 추가로 필요하다.
5. `ssm` 모드에서는 인스턴스 역할에 `/lcamtest/prd/*` 에 대한 `ssm:GetParameter` 권한이 필요하다(`GetParametersByPath` 와 별개 액션).

### 서버에서 즉시 켜는 `/up` 500 (T12, 배포 없이 한 대만)

```bash
sudo touch /var/www/shared/FAULT_UP_500   # /up → 500
sudo rm    /var/www/shared/FAULT_UP_500   # 복구
```

### T4 재현 순서

1. 정상 배포 N-1 (성공).
2. `fault=stop_fail` 로 배포 N. N 의 ApplicationStop 은 N-1 의 `stop.sh` 를 쓰므로 성공하고, 배포 N 은 Succeeded.
3. `fault=none` 으로 배포 N+1. ApplicationStop 이 **N 의 `stop.sh`** 를 실행해서 실패 → Failed.
4. 자동 롤백이 켜져 있으면 CodeDeploy 가 N(마지막 성공 리비전)을 재배포하려 하고, 그 ApplicationStop 도 N 의 `stop.sh` 라서 롤백도 실패한다. 복구 배포는 롤백을 끄고 ApplicationStop 실패를 무시한다:

```bash
aws deploy create-deployment --application-name lc-app --deployment-group-name lc-web \
  --s3-location bucket=lc-deploy-866477832211,key=deploy/<정상 SHA>.zip,bundleType=zip \
  --file-exists-behavior OVERWRITE --ignore-application-stop-failures \
  --auto-rollback-configuration enabled=false
```

## 비상 수동 롤백 (CodeDeploy 를 거치지 않음)

```bash
ls -1t /var/www/releases/                       # 이전 릴리스 확인
sudo ln -sfn /var/www/releases/<이전 id> /var/www/current
sudo systemctl reload php8.4-fpm                # opcache 반영
curl -s localhost/version
```

주의: 이 롤백은 그 서버 한 대에만 적용된다. 이후 ASG 가 새 인스턴스를 띄우면 CodeDeploy 가 기억하는 **마지막 성공 리비전**이 올라온다 (수동으로 되돌린 버전이 아님). `after_install.sh` 가 `current` 교체 때 위 명령을 로그에 찍어 준다.

## SSM 파라미터 (after_install.sh 가 읽음)

경로 `/lcamtest/prd/` 아래 파라미터가 `shared/.env` 의 `KEY=값` 이 된다 (이름의 마지막 구간이 키). 최소 구성은 SecureString 3개이다. 파라미터가 하나도 없으면 AfterInstall 이 실패한다.

| 이름 | 예시 값 |
|---|---|
| `/lcamtest/prd/APP_NAME` | `lcamtest` |
| `/lcamtest/prd/APP_ENV` | `production` |
| `/lcamtest/prd/APP_KEY` | 임의 문자열 (더미) |

## 로그 위치

| 무엇 | 어디 |
|---|---|
| 훅 스크립트 출력 | 배포 상세의 이벤트별 로그, 서버의 `/opt/codedeploy-agent/deployment-root/deployment-logs/codedeploy-agent-deployments.log` |
| 에이전트 | `/var/log/aws/codedeploy-agent/` |
| heartbeat (scheduler, queue) | `/var/www/shared/storage/logs/heartbeat.log` |
| 워커 이벤트 (sigterm → graceful exit) | `/var/www/shared/storage/logs/worker.log` |

에이전트 2.x 의 경로는 문서상 1.x 와 같다고 되어 있으나 인스턴스에서 직접 확인하지 않았다.

## 알려진 한계 (데모라서 그대로 둠)

- Queue 인스턴스를 재부팅하면 워커는 다음 배포 때까지 안 뜬다 (`autostart=false`, 같은 AMI 를 Web 과 공유하기 위함).
- `stopwaitsecs=90` (supervisor) < `stop.sh` timeout 120초 (appspec). 워커 작업 시간(기본 20초)을 늘리면 이 관계를 같이 조정한다.
- 파라미터 이름의 마지막 구간만 키로 쓰므로 하위 경로에 같은 이름이 있으면 충돌한다.

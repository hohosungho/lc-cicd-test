# PROPOSAL: 설계·비용 제안서 (승인 대기)

> **변경 메모 (사용자 지시로 방향 변경, 이 문서 본문은 수정하지 않음)**
> - 승인 절차는 생략한다. AWS 리소스는 에이전트가 만들지 않고 사용자가 콘솔에서 직접 만든다. 에이전트는 AWS 변경 명령을 실행하지 않는다. 따라서 `infra/cli/` 스크립트 구축 계획과 5장의 단계별 AWS 생성·허용 범위는 적용하지 않는다.
> - 앱은 최소로 만든다(버전/태그/SHA/instance-id/AZ/시간 + SHA 기반 배경색, `/up`, `/version`). 고장 스위치와 라이브 스트립 등은 필요한 만큼만 넣는다. GitHub Actions는 최소본이다.
> - 핵심 산출물: `docs/CONSOLE-GUIDE.md`(콘솔 메뉴 경로·입력값·순서·확인 방법), 훅 스크립트·appspec·골든 AMI 스크립트, 사용자가 직접 수행하는 시험 절차서(`TEST-GUIDE`/`RESULTS` 템플릿), `TEARDOWN`.
> - 1·2·6·7장의 CodeDeploy/ASG 동작 설명, 비용, §6 순서 충돌(ASG를 배포 그룹에 먼저 등록, 전용 태그, OIDC `sub`, `Terminate` 중지와 T8)은 가이드에 그대로 반영한다.

- 작성 기준: `lcampus-cicd.md` §0~§10 + [변경]/[추가] ([변경] 우선), `docs/CONTEXT.md`
- 계정 확인: `aws sts get-caller-identity` → Account 866477832211 (일치). 이 단계에서는 읽기 전용 조회만 했고 리소스는 만들지 않았다.
- 공식 문서 인용은 모두 `https://docs.aws.amazon.com/...` 이며, 문서로 확인하지 못한 동작은 "시험으로 확인"이라고 적고 `docs/RESULTS.md`에 기록한다.

---

## 1. 아키텍처 요약 (CodeDeploy + ASG 중심)

### 1-1. 전체 구성

```
GitHub Actions ──OIDC──▶ IAM role ──▶ S3 deploy 버킷 (deploy/<sha>.zip)
                                   └▶ CodeDeploy create-deployment ─┐
                                                                    ▼
 내 IP(211.212.235.69/32) ─▶ ALB(80) ─▶ TG(lc-tg-web, /up)    CodeDeploy 서비스
                                          │  ▲ 제외/재등록           │ (에이전트가 폴링)
                          ┌───────────────┴──┴──────────┐            ▼
                          │ Web ASG (min0/desired0/max3)│◀── 배포 그룹 lc-web-dg
                          │  2a·2c public 서브넷        │
                          └─────────────────────────────┘
        Queue 1대 (lc-queue-dg, 태그) · Scheduler 1대 (lc-scheduler-dg, 태그)
        VPC lc-vpc: public 서브넷 2개 + IGW + S3 게이트웨이 엔드포인트 (NAT 없음)
        관리: SSM Session Manager (SSH 없음)
```

- CodeDeploy 애플리케이션 1개(`lc-app`), 배포 그룹 3개(`lc-web-dg`, `lc-queue-dg`, `lc-scheduler-dg`). 같은 zip을 3개 그룹에 쓰고, 훅 스크립트가 `DEPLOYMENT_GROUP_NAME`으로 역할을 나눈다.
- 모두 in-place, 자동 롤백(배포 실패 시) 켬. Web은 `CodeDeployDefault.OneAtATime` + `outdated-instances-strategy=UPDATE`.

### 1-2. 배포 한 번이 인스턴스 한 대에서 진행되는 순서

in-place + ALB(타깃 그룹 연결) 배포의 인스턴스별 수명주기 이벤트다. 스크립트를 걸 수 있는 훅은 굵게 표시했다.

| 순서 | 이벤트 | 스크립트 | 우리 구성에서 하는 일 |
|---|---|---|---|
| 1 | BeforeBlockTraffic / BlockTraffic / AfterBlockTraffic | BlockTraffic은 불가 | 인스턴스를 TG에서 제외(draining). 훅은 appspec에 쓰지 않는다. |
| 2 | **ApplicationStop** | 이전 성공 리비전의 스크립트 | graceful stop. 첫 배포에는 실행되지 않는다. |
| 3 | DownloadBundle | 불가 | 에이전트가 zip을 `/opt/codedeploy-agent/deployment-root/<dg-id>/<deployment-id>/deployment-archive`에 푼다. |
| 4 | **BeforeInstall** | 새 리비전 | 스테이징 디렉터리 정리, 디스크·권한 점검. |
| 5 | Install | 불가 | `files:` 대로 `/` → `/var/www/_incoming` 복사(OVERWRITE). |
| 6 | **AfterInstall** | 새 리비전 | SSM에서 `.env` 생성 → `releases/<DEPLOYMENT_ID>`로 이동 → shared 링크 → artisan cache → `current` 교체. |
| 7 | **ApplicationStart** | 새 리비전 | `php-fpm reload`(Queue는 supervisor 재시작, Scheduler는 cron 유지). |
| 8 | **ValidateService** | 새 리비전 | `curl /up` 재시도 + 릴리스 SHA 일치 확인. |
| 9 | BeforeAllowTraffic / AllowTraffic / AfterAllowTraffic | AllowTraffic은 불가 | TG에 재등록하고 healthy가 될 때까지 최대 1시간 대기. |

- 근거: 훅 목록·ApplicationStop·DownloadBundle 설명·in-place에 Block/Allow 훅 6개가 적용되는 조건은 [AppSpec 'hooks' section](https://docs.aws.amazon.com/codedeploy/latest/userguide/reference-appspec-file-structure-hooks.html). 재등록 후 healthy 대기 1시간은 [Integrating CodeDeploy with Elastic Load Balancing](https://docs.aws.amazon.com/codedeploy/latest/userguide/integrations-aws-elastic-load-balancing.html).
- 1번과 9번이 2번~8번의 앞뒤에 붙는 정확한 위치는 문서의 순서도 그림에만 있어 텍스트로 확인하지 못했다. 첫 배포(T1)에서 `aws deploy get-deployment-target`의 `lifecycleEvents` 시작·종료 시각으로 실제 순서와 구간별 소요 시간을 기록한다.
- 한 가지 주의: ApplicationStop은 "이전 성공 리비전의 AppSpec과 스크립트"를 쓴다([같은 문서](https://docs.aws.amazon.com/codedeploy/latest/userguide/reference-appspec-file-structure-hooks.html)). 그래서 지금 배포하는 zip의 stop.sh를 고쳐도 이번 배포에는 적용되지 않는다. T4가 이 성질을 재현한다.

### 1-3. 롤링(OneAtATime)과 TG 제외·재등록

- 한 번에 한 대만 배포한다. 대상 대수가 2 이상이면, 마지막 인스턴스가 실패해도 전체 배포는 Succeeded로 표시된다. 마지막 전 인스턴스가 실패하면 즉시 Failed다. 대상이 1대뿐인 그룹은 그 한 대가 성공해야 Succeeded다. ([Working with deployment configurations](https://docs.aws.amazon.com/codedeploy/latest/userguide/deployment-configurations.html))
- 배포 중인 인스턴스는 TG에서 제외되고, 배포가 끝나면 선택한 모든 TG에 다시 등록된다. 배포 그룹에 TG를 연결할 때는 대상 인스턴스가 그 TG에 이미 등록돼 있어야 한다. ([Create a deployment group for an in-place deployment](https://docs.aws.amazon.com/codedeploy/latest/userguide/deployment-groups-create-in-place.html))
- TG 제외 시 deregistration delay(프로파일 A 300초 / B 30초)가 실제로 배포 시간에 얼마나 더해지는지는 문서만으로 단정할 수 없다. 문서는 "진행 중 요청과 연결이 없으면 ELB가 즉시 제외를 완료한다"고 하면서 상태 표시는 delay가 끝날 때까지 draining이라고 한다([Target group attributes](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/edit-target-group-attributes.html)). CodeDeploy가 어느 쪽을 기다리는지는 T17에서 측정한다.

### 1-4. ASG 연동과 launch deployment

- 배포 그룹에 ASG를 넣으면 CodeDeploy가 서비스 역할로 ASG에 접근해 **launch hook**(항상 켜짐, 끌 수 없음)을 설치하고, 선택하면 termination hook도 설치한다. ([Integrating CodeDeploy with Amazon EC2 Auto Scaling](https://docs.aws.amazon.com/codedeploy/latest/userguide/integrations-aws-auto-scaling.html))
- 스케일 아웃 흐름: 인스턴스가 `Pending:Wait`에 들어간다 → launch hook이 SQS로 CodeDeploy에 알린다 → CodeDeploy가 **launch deployment**(해당 배포 그룹의 마지막 성공 리비전)를 시작하고 5분마다 heartbeat를 보낸다 → 성공이면 `CONTINUE`(InService로 진행, 그 뒤 ASG가 TG에 등록), 실패면 `ABANDON`(ASG가 인스턴스를 종료하고 필요하면 desired를 맞추려고 다시 시작). 같은 문서.
- launch deployment에서 쓸 수 있는 훅은 ApplicationStop, BeforeInstall, AfterInstall, ApplicationStart, ValidateService, BeforeAllowTraffic, AfterAllowTraffic이다. 새 인스턴스에는 이전 AppSpec이 없으므로 ApplicationStop은 실행되지 않는다. ([훅 가용성 표](https://docs.aws.amazon.com/codedeploy/latest/userguide/reference-appspec-file-structure-hooks.html))
- `outdated-instances-strategy=UPDATE`: 배포 도중 스케일 아웃된 인스턴스는 최신이 아니라 직전에 배포된 리비전을 받는다. UPDATE이면 CodeDeploy가 첫 배포 직후 후속 배포를 자동으로 시작해 뒤처진 인스턴스를 최신화한다(T9). ([Configure advanced options](https://docs.aws.amazon.com/codedeploy/latest/userguide/deployment-groups-configure-advanced-options.html))
- 배포 중 스케일 인이 일어나면 종료와 배포 사이에 경쟁이 생기고, 정상 대수가 minimum healthy hosts 아래로 내려가면 배포가 실패한다. 이를 막으려면 `Terminate` 같은 프로세스를 중지한다. ([같은 문서](https://docs.aws.amazon.com/codedeploy/latest/userguide/integrations-aws-auto-scaling.html), [Suspending processes during deployments](https://docs.aws.amazon.com/codedeploy/latest/userguide/integrations-aws-auto-scaling-suspend-processes.html))
- 알려진 함정(문서에 있음): launch deployment가 계속 실패하면 인스턴스가 뜨고 죽기를 반복한다. 마지막 성공 리비전이 망가진 상태에서 0→1 스케일 아웃을 하면 InService 인스턴스가 없어져 교착 상태가 된다. 해법은 태그가 붙은 별도 인스턴스를 배포 그룹에 넣고 정상 리비전을 배포하는 것이다. ([Troubleshoot Amazon EC2 Auto Scaling issues](https://docs.aws.amazon.com/codedeploy/latest/userguide/troubleshooting-auto-scaling.html)) 이것이 중단 기준 "3회 연속 뜨고 죽음"의 전형이다.

### 1-5. 롤백이 동작하는 방식

- 롤백은 "복원"이 아니라 **마지막으로 성공한 리비전을 새 배포(새 deployment ID)로 다시 배포**하는 것이다. 자동 롤백(배포 실패 시)과 수동 롤백(이전 리비전으로 새 배포) 둘 다 같다. ([Redeploy and roll back a deployment](https://docs.aws.amazon.com/codedeploy/latest/userguide/deployments-rollback-and-redeploy.html))
- 새 배포 전에 에이전트는 cleanup 파일(`/opt/codedeploy-agent/deployment-root/deployment-instructions/<dg-id>-cleanup`)에 적힌, 이전에 설치한 파일만 지운다. 스크립트가 만든 것은 되돌리지 않는다. 같은 문서.
- 우리 구조에서의 의미: CodeDeploy가 지우는 것은 `/var/www/_incoming`(files로 설치한 것)뿐이다. `releases/<ID>/`, `shared/`, `current` 링크는 스크립트가 만든 것이라 남는다. 롤백 배포는 AfterInstall에서 **새 릴리스 디렉터리(롤백 배포의 ID)** 를 만들고 `current`를 거기로 바꾼다. 이 동작을 RESULTS.md에 기록한다.
- 롤백 두 경로(요구사항 [추가]): ① CodeDeploy 롤백(자동·수동)과 ② 서버에서 `current` 링크를 이전 릴리스 디렉터리로 되돌리는 비상 롤백. ②는 CodeDeploy의 "마지막 성공 리비전" 기록을 바꾸지 않는다. 따라서 ② 직후 ASG가 새 인스턴스를 띄우면 launch deployment는 (②로 돌려놓은 버전이 아니라) CodeDeploy가 기억하는 마지막 성공 리비전을 받을 것으로 예상한다. 문서 근거는 위 launch deployment 설명이고, 실제 결과는 시험으로 기록한다.

---

## 2. 비용 추정

### 2-1. 단가 (ap-northeast-2, 2026-11 조회)

| 항목 | 단가 | 출처 |
|---|---|---|
| EC2 t3.small (Linux, 온디맨드) | $0.0260/h | AWS Price List API (`aws pricing get-products`, AmazonEC2) |
| EC2 t4g.small | $0.0208/h (t3 대비 약 20% 저렴, Arm) | 같음 |
| ALB 시간당 | $0.0225/h | Price List API (AWSELB, `APN2-LoadBalancerUsage`) |
| ALB LCU | $0.008/LCU-h | 같음 (`APN2-LCUUsage`) |
| 퍼블릭 IPv4 (사용 중) | $0.005/h | [Amazon VPC pricing](https://aws.amazon.com/vpc/pricing/) |
| EBS gp3 | $0.0912/GB-월 | Price List API (`APN2-EBS:VolumeUsage.gp3`) |
| EBS 스냅샷(AMI) | $0.05/GB-월 | Price List API (`APN2-EBS:SnapshotUsage`) |
| S3 Standard | $0.025/GB-월, PUT $0.0045/1,000건 | Price List API (AmazonS3) |
| 인터넷 아웃바운드 | $0.126/GB (첫 10TB, 무료 구간 별도) | Price List API (AWSDataTransfer) |
| CodeDeploy (EC2/온프레미스 인스턴스 대상 배포) | 추가 요금 없음 | [CodeDeploy pricing](https://aws.amazon.com/codedeploy/pricing/) |
| SSM Session Manager, ASG, SSM 표준 파라미터, 게이트웨이 엔드포인트, IAM | 무료 | 각 서비스 요금 페이지 |

### 2-2. 가정

- 인스턴스: t3.small 8GB gp3(암호화), 인스턴스마다 퍼블릭 IPv4 1개. 인터넷 연결 ALB는 AZ 2개이므로 퍼블릭 IPv4 2개가 별도로 붙는다. LCU는 최소 1로 가정한다.
- 골든 AMI 빌드용 인스턴스(builder)는 1~2시간만 쓴다. AMI 스냅샷은 실사용 3GB 안팎으로 3개 정도 만든다고 가정한다.
- 시간 환산은 730시간/월.

### 2-3. 시간당 비용

| 상태 | 구성 | 시간당 |
|---|---|---|
| 기본 인프라만 | ALB 0.0225 + IPv4 2개 0.01 + LCU 0.008 | 약 $0.04 |
| 단독 단계 | 기본 + Web·Queue·Scheduler 3대(인스턴스 0.026 + IPv4 0.005 + EBS 0.001) | 약 $0.14 |
| ASG 2대 단계 | 기본 + Web 2 + Queue + Scheduler (4대) | 약 $0.17 |
| 최대(Web 3대 + Q + S) | 기본 + 5대 | 약 $0.20 |

### 2-4. 시험 기간 전체 (하루 8시간 × 3일 = 활성 24시간)

| 항목 | 계산 | 비용 |
|---|---|---|
| ALB (밤에도 유지, 72시간) | 72h × $0.0405 | 약 $2.9 |
| EC2 + 인스턴스 IPv4 (평균 4대 × 24h) | 4 × 24 × $0.031 | 약 $3.0 (5대 가정 시 $3.7) |
| EBS (볼륨 약 6개 × 72h) | 6 × 8GB × $0.0912 × 72/730 | 약 $0.4 |
| AMI 스냅샷 | 3 × 3GB × $0.05 × 3/30 | 약 $0.05 |
| S3·요청·데이터 전송 | 소형 zip 수십 개, 응답 수 MB | $0.05 미만 |
| **합계** | | **약 $6.5 (최대 약 $8)** |

- 인스턴스를 낮 시간에만 켜는 가정이다. 모두 72시간 켜 두면 약 $15.
- 방치하면 최대 구성 기준 약 $0.20/h = 월 약 $147이다. ALB만 남아도 월 약 $29다.
- t3는 CPU 크레딧이 기본 unlimited 모드라 부하 시험(스케일 정책) 때 소액이 더 붙을 수 있다(수 분 × 인스턴스 수 단위). 이 항목은 가격 페이지로 확인하지 못했으므로 시험 후 청구에서 확인한다.
- NAT 게이트웨이, RDS, ElastiCache는 만들지 않는다([변경]).

### 2-5. 시험이 끝나면 내리는 방법 (요약)

`infra/cli/99-teardown.sh`와 `docs/TEARDOWN.md`로 제공한다. 순서는 다음과 같다. 삭제는 실행 전에 사용자 확인을 받는다.

1. 비상/종료 준비: `suspend-processes` → ASG `min=0 desired=0`
2. CodeDeploy: 배포 그룹 3개 → 애플리케이션 삭제(ASG 연결을 비워 CodeDeploy가 만든 lifecycle hook 정리 확인)
3. ASG → Launch Template → ALB 리스너 → ALB → TG
4. 단독 인스턴스(Web·Queue·Scheduler·builder) 종료
5. AMI 등록 해제 + 스냅샷 삭제
6. S3 버킷 비우기 후 삭제, SSM 파라미터 삭제
7. IAM: 인스턴스 프로파일·역할, CodeDeploy 서비스 역할, GitHub OIDC 역할과 공급자
8. 네트워크: 게이트웨이 엔드포인트 → 서브넷 → 라우트 테이블 → IGW → SG → VPC
9. 확인: `aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=lcamtest` 결과가 비어 있는지 확인. 청구는 Cost Explorer에서 `Project=lcamtest` 태그로 확인.

---

## 3. 저장소·IaC 구조 제안

Terraform은 쓰지 않는다. 구축은 AWS CLI 스크립트(`infra/cli/`)와 콘솔 절차로 한다.

```
lcam-cicd-demo/
├─ appspec.yml                  # 번들(zip) 루트로 들어간다
├─ fault.conf                   # 고장 스위치 기본값 (FAULT=none)
├─ app/                         # Laravel 최소 앱. 번들 루트에 합쳐진다
├─ scripts/                     # CodeDeploy 훅 (번들의 scripts/ 로 들어간다)
│   ├─ lib.sh  stop.sh  before_install.sh  after_install.sh  start.sh  validate.sh
├─ .github/
│   ├─ workflows/deploy.yml     # 빌드 → S3 → create-deployment → wait
│   └─ scripts/build-bundle.sh  # 번들 조립·zip (번들에 포함되지 않음)
├─ infra/
│   ├─ cli/                     # 번호순 스크립트 + env.sh(공통 변수) + lib.sh(계정 확인, 태그)
│   │   00-preflight.sh 10-network.sh 20-iam.sh 30-s3-ssm.sh 40-alb-tg.sh
│   │   45-tg-profile.sh 50-instances.sh 60-codedeploy.sh 70-asg.sh 80-scaling.sh 99-teardown.sh
│   └─ ami/                     # provision.sh(런타임 설치. user-data와 AMI 빌드 공용), bake-ami.sh
├─ docs/                        # PROPOSAL / CONTEXT / STATE / ARCHITECTURE / RESULTS / TEARDOWN / evidence/
└─ README.md                    # 고객 운영 환경과의 차이 포함
```

**zip 루트 기준 배치** (CodeDeploy는 훅 위치를 번들 루트 기준 상대 경로로 해석한다: [AppSpec 'hooks' section](https://docs.aws.amazon.com/codedeploy/latest/userguide/reference-appspec-file-structure-hooks.html))

```
<bundle>.zip
├─ appspec.yml            ← 반드시 루트
├─ scripts/*.sh           ← 훅 (실행 비트, LF)
├─ release.json           ← CI가 생성: version, tag, sha, built_at
├─ fault.conf             ← CI가 생성: 고장 스위치
└─ (Laravel: artisan, app/, bootstrap/, config/, public/, routes/, vendor/ ...)
```

- 요구사항 §5-1의 appspec을 그대로 쓴다: `files: / → /var/www/_incoming`, `file_exists_behavior: OVERWRITE`, 훅 5개(`scripts/stop.sh` 등), `runas: root`.
- 설계 규칙은 요구사항 §5-1·§5-3과 같다: 스테이징에만 설치 → `releases/$DEPLOYMENT_ID`로 이동 → `shared/`(.env, storage) 링크 → `ln -sfn`으로 `current` 교체, 오래된 릴리스는 N개만 보관, 모든 스크립트는 `set -euo pipefail`, 멱등, 비밀 출력 금지, `AWS_DEFAULT_REGION=ap-northeast-2`.
- 로컬에 php·composer가 없으므로 코드 단계에서 `brew install php composer`(로컬 개발 도구, 되돌릴 수 있음)로 Laravel 뼈대를 만든다.
- 기존 원격 저장소 `hohosungho/lc-cicd-test`에는 커밋 1개(README만)가 있다. 첫 push 때 원격을 연결해 fetch 후 병합(force push 없음)한다.
- 저장소가 **공개**라서 계정 ID·내 IP 같은 값은 스크립트에 직접 쓰지 않는다. 스크립트가 실행 시 `sts get-caller-identity`로 계정 ID를 얻고, 허용 IP는 git에 올리지 않는 `infra/cli/env.local.sh`에서 읽는다. 워크플로의 역할 ARN은 GitHub repository variable로 둔다. (`docs/CONTEXT.md`와 이 문서에는 이미 값이 들어 있다. 5·8장 참고.)

---

## 4. 앱 UI 안과 고장 스위치

### 4-1. 앱 UI

목적은 "롤링 중 어떤 서버가 어떤 버전인지"를 한눈에 보는 것이다. Laravel 최소 앱(DB·Redis 없음: `SESSION_DRIVER=cookie`, `CACHE_STORE=file`, `QUEUE_CONNECTION=sync`)에 Blade 뷰 1개를 둔다.

- **배경색**: 릴리스 SHA 앞 6자리에서 색조(hue)를 뽑아 HSL(채도 65%, 명도 40%)로 칠한다. 글자는 흰색. 커밋이 바뀌면 색이 바뀌므로 서버별 버전 차이가 색으로 보인다.
- **큰 글씨**: 버전(`1.0.<run_number>`), 태그(워크플로 입력 `release_tag`, 없으면 `main`), 릴리스 SHA(앞 7자리 크게, 전체는 작게), instance-id, AZ, 서버 시간, 배포 그룹 역할.
- instance-id와 AZ는 IMDSv2(토큰 → `meta-data/instance-id`, `placement/availability-zone`)로 조회하고 1분간 파일 캐시한다. IMDS에 닿지 않으면 `unknown`으로 표시한다.
- **라이브 스트립**: 페이지가 1초마다 `/version`을 호출해 최근 20개 응답을 색 칩(SHA 색 + instance-id 끝 4자리)으로 나열한다. 롤링 배포 중 요청이 ALB에서 어느 서버로 가는지, 5xx가 나는지 눈에 보인다.
- 고장 스위치가 켜져 있으면 상단에 빨간 띠로 `FAULT: <종류> target=<대상>`을 표시한다.
- 경로: `/`(위 화면), `/version`(JSON: sha, version, tag, instance-id, az), `/up`(Laravel 기본 헬스 + 고장 스위치).
- Node/Vite 빌드는 하지 않는다(CSS는 뷰 안에 인라인). 8장 질문 2 참고.

### 4-2. 고장 스위치 설계

두 층으로 나눈다.

**(가) 리비전에 실리는 스위치: `fault.conf`** — 번들 루트에 들어가는 파일. 저장소의 기본값은 `FAULT=none`. 워크플로 수동 실행(`workflow_dispatch`)의 입력(`fault`, `fault_target`)이 이 파일을 덮어쓴다. 배포된 리비전마다 고장이 고정되므로 재현이 쉽다.

```
FAULT=none | up500 | before_install_fail | after_install_fail | start_fail | validate_fail | stop_fail
FAULT_TARGET=all | instance:i-0abc... | az:ap-northeast-2c
```

- 각 훅 스크립트는 맨 위에서 `lib.sh`의 `maybe_fail <이 훅 이름>`을 호출한다. `FAULT`가 이 훅과 일치하고 `FAULT_TARGET`이 이 인스턴스(IMDS의 instance-id·AZ)와 맞으면 로그를 남기고 `exit 1`한다.
- `up500`: `/up`이 500을 반환한다. 앱 코드가 `release`의 `fault.conf`를 읽는다.

**(나) 서버에서 즉시 켜는 스위치: 플래그 파일** — `/var/www/shared/FAULT_UP_500`. SSM Session Manager 또는 `aws ssm send-command`로 한 대에서만 `touch`/`rm` 한다. 배포 없이 `/up`을 500으로 만들 수 있어 T12에 쓴다.

| 시험 | 재현 방법 |
|---|---|
| T2 ValidateService 실패 → 자동 롤백 | `FAULT=validate_fail, target=all`로 배포(단독 Web 1대 단계). 배포가 Failed → 자동 롤백 → 이전 성공 리비전 복귀 시간을 기록 |
| T3 BeforeInstall / AfterInstall / ValidateService 각각 실패 | `before_install_fail`, `after_install_fail`, `validate_fail`로 세 번 배포, 각각 이전 상태 복귀 확인 |
| T4 이전 리비전의 stop 스크립트 고장 | 리비전 N을 `FAULT=stop_fail`로 정상 배포(stop.sh는 N에서만 고장, 배포는 성공) → 정상 리비전 N+1을 배포하면 ApplicationStop이 **N의 stop.sh**를 써서 실패 → `--ignore-application-stop-failures`로 재배포해 복구. 이 배포는 `--auto-rollback-configuration enabled=false`로 롤백을 끄고 한다(8·6장 참고) |
| T7 첫 인스턴스 실패 | 직전 배포에서 CodeDeploy가 처리한 순서를 `list-deployment-targets`로 확인 → 첫 번째 인스턴스를 `FAULT_TARGET=instance:<id>`로 지정 → Failed + 롤백 기대 |
| T7 마지막 인스턴스만 실패 | 같은 방식으로 마지막 순서 인스턴스를 지정 → 전체 Succeeded 여부 확인(롤백 안 됨 기대). 배포 순서가 바뀌면 그 사실도 기록하고 다시 지정한다 |
| T12 `/up` 실패 | 플래그 파일을 한 대에 생성 → ELB 헬스체크 실패 → ASG 교체(자동 복구 프로세스 해제 후에만) |

- T7처럼 Succeeded로 끝난 고장 리비전은 CodeDeploy의 "마지막 성공 리비전"이 된다. 그 직후 스케일 아웃이 일어나면 새 인스턴스가 고장 리비전을 받는다. 그래서 인스턴스 고장은 **`instance:` 지정만** 쓰고(새 인스턴스는 ID가 달라 영향 없음) `az:` 지정은 ASG의 launch가 켜진 동안 쓰지 않는다. T7 직후 곧바로 정상 리비전을 배포한다. (교착 위험: [Troubleshoot Auto Scaling](https://docs.aws.amazon.com/codedeploy/latest/userguide/troubleshooting-auto-scaling.html))
- 앱 쪽 실제 변경은 최소다: 훅의 `maybe_fail`, `/up`의 500 분기, UI의 빨간 띠.

---

## 5. 이후 단계 계획

각 단계는 사용자 확인 없이 진행한다. 단 삭제, 고비용 리소스, 중단 기준은 `docs/CONTEXT.md`의 [승인 정책]대로 멈추고 묻는다. 비용이 드는 리소스는 만들기 전에 시간당 비용을 한 줄로 알린다.

| 단계 | 내용 | 산출물 / 확인 |
|---|---|---|
| 1 코드 작성 (AWS 없음) | Laravel 최소 앱, UI, 고장 스위치, appspec + 훅 5개 + lib.sh, `build-bundle.sh`, GitHub Actions 워크플로, 로컬 검증(`php artisan serve`, zip 구조, 스크립트 shellcheck·`bash -n`). push | 로컬에서 `/`·`/version`·`/up` 동작, zip 루트 구조 확인 |
| 2 기본 인프라 | 계정 확인 → VPC·public 서브넷 2·IGW·S3 게이트웨이 엔드포인트·SG → IAM(인스턴스 역할/프로파일, CodeDeploy 서비스 역할, GitHub OIDC 공급자·역할) → S3 버킷(deploy) → SSM 파라미터 → ALB + TG(프로파일 A) | STATE.md 기록. 이 시점 비용 ≈ $0.04/h |
| 3 단독 인스턴스 + 첫 배포 | Web·Queue·Scheduler 단독 인스턴스(Ubuntu 24.04, `provision.sh`를 user-data로) → Web을 TG에 수동 등록 → 배포 그룹 3개(Web은 태그 + TG, Queue/Scheduler는 태그) → GitHub Actions로 첫 배포 | T1 (Succeeded, `/up` 200, TG healthy). 비용 ≈ $0.14/h |
| 4 골든 AMI | builder 인스턴스에서 `provision.sh`로 런타임 설치 → 에이전트 정지·정리 → AMI 생성 → builder 종료 → 새 인스턴스에서 launch deployment 성공 여부는 6단계(ASG 도입)에서 시험 | AMI ID, 정리 증빙 |
| 5 T2~T4 | 단독 Web 1대에서 고장 스위치 시험 | RESULTS.md |
| 6 ASG 도입 (§6 순서, 수동 모드) | Launch Template(골든 AMI, 퍼블릭 IP 명시) → ASG `min0/desired0/max3`, TG 연결, 헬스체크 ELB, 유예 300초 → **TG 연결 후** 배포 그룹에 ASG 추가(6장 참고) → 프로세스 중지(`ReplaceUnhealthy`, `Terminate`, `AZRebalance`, `ScheduledActions`, `AlarmNotification`) → `desired=1`(launch deployment 확인) → `desired=2` | T5 |
| 7 T6~T8 | 롤링 중 0.5초 간격 요청, 첫/마지막 인스턴스 실패, 인스턴스 종료 후 교체(T8은 6장 4번 참고) | RESULTS.md |
| 8 자동 복구 해제 후 T9~T12 | 프로세스 재개 → 배포 중 desired+1, 스케일 인, 한 AZ 인스턴스 중지, `/up` 실패 | RESULTS.md |
| 9 스케일 정책·T14·T15·T17·롤백 2경로 | 목표 추적 정책 + 부하 → 증설 확인, Queue/Scheduler 시험(T14 축소), zip 만료 상태 롤백·증설(T15), TG 프로파일 A↔B 배포 시간 비교(T17), 롤백 ①②와 ② 후 ASG 신규 인스턴스 버전 확인 | RESULTS.md |
| 10 문서 | ARCHITECTURE.md, RESULTS.md 정리, TEARDOWN.md, README의 "고객 운영 환경과의 차이" | |
| 11 teardown | 사용자 확인 후 실행 | `get-resources` 결과 비어 있음 |

### 5-1. 이 승인으로 확정하는 허용 범위

**승인 없이 진행하는 것 (시험 절차가 요구하거나 내가 만든 임시 객체)**

- 인스턴스 종료·중지: T8(`terminate-instance-in-auto-scaling-group`), T10(스케일 인 = desired 감소), T11(한 AZ 인스턴스 중지·재시작), T12(헬스체크 실패로 ASG가 교체하는 인스턴스), 배포 실패로 ASG가 `ABANDON`하는 인스턴스
- 야간·유휴 비용 절감: Queue·Scheduler·단독 Web 인스턴스 stop/start, ASG `desired`를 0으로 줄였다가 다음 날 다시 올리기(재기동 시 launch deployment가 시험 데이터가 된다)
- 단독 Web 인스턴스 정리: ASG 인스턴스 2대 이상이 healthy가 된 뒤 TG에서 제외하고 종료, 배포 그룹의 태그 필터 제거(§6-7)
- 빌더 인스턴스: AMI 생성 후 종료. 빌더가 만든 임시 파일 삭제
- 시험용 객체: 고장 리비전 zip, T15용으로 지우는 `deploy/<sha>.zip` 1개(만료 상태 재현), `/var/www/shared/FAULT_UP_500` 플래그 파일, 시험 중 만든 임시 CLI 입력 파일
- 설정 변경: 배포 그룹·ASG·TG·SG·Launch Template 수정(새 버전 추가 포함), S3 수명주기 규칙 설정과 원복, 프로세스 중지·재개, `--ignore-application-stop-failures` 배포

**반드시 멈추고 묻는 것**

- 99-teardown 실행 전체, AMI 등록 해제·스냅샷 삭제, 버킷·객체 삭제(위 임시 객체 제외), IAM·VPC 삭제
- NAT·RDS 등 고비용 리소스, 큰 인스턴스 타입(t3/t4g.small 급을 넘는 것)
- 계정 불일치
- 중단 기준 발동: 인스턴스가 3회 연속 뜨고 죽음 / 정상 대수 0이 10분 이상 / **예상하지 않은** 롤백 실패 → §7 비상 절차 안내 후 멈춤. (T4처럼 롤백 실패를 의도한 시험은 해당하지 않는다.)

---

## 6. 요구사항 §6 순서와 기술적으로 충돌할 수 있는 점

### 6-1. launch deployment를 쓰려면 ASG가 배포 그룹에 먼저 등록돼야 하는데, §6-7은 "마지막에" 바꾸라고 한다

- 문서: launch hook은 배포 그룹에 ASG를 넣을 때 CodeDeploy가 ASG에 설치한다([Integrating CodeDeploy with Amazon EC2 Auto Scaling](https://docs.aws.amazon.com/codedeploy/latest/userguide/integrations-aws-auto-scaling.html)). §6-4의 "desired=1 → launch deployment로 투입 확인"을 하려면 그 전에 ASG가 Web 배포 그룹에 들어 있어야 한다.
- 문서: 한 배포 그룹은 ASG와 태그 지정 인스턴스를 함께 가질 수 있다. ASG 프로세스 중지 문서가 "배포 그룹에 ASG가 있고, 태그로 지정한 인스턴스도 포함될 수 있다"고 쓴다([Suspending processes during deployments](https://docs.aws.amazon.com/codedeploy/latest/userguide/integrations-aws-auto-scaling-suspend-processes.html)).
- **제안**: §6-2(ASG 생성)에서 TG 연결을 끝낸 직후 같은 Web 배포 그룹에 ASG를 **추가**한다(태그 필터는 그대로 둔다). §6-7은 "태그 필터 제거"만 남기고, 이 시점에 단독 인스턴스를 정리한다. 최종 상태는 요구사항과 같다. 같은 배포 그룹을 끝까지 쓰는 이유는 launch deployment가 그 그룹의 마지막 성공 리비전을 쓰기 때문이다(새 그룹을 만들면 성공 이력이 없다).
- 순서 제약: 문서가 "ASG와 ELB를 함께 쓰는 배포 그룹은 ASG에 로드밸런서(TG)를 먼저 연결하고 배포를 만들라"고 경고한다([Create a deployment group for an in-place deployment](https://docs.aws.amazon.com/codedeploy/latest/userguide/deployment-groups-create-in-place.html)). 그래서 ASG 생성 시 TG를 연결한 뒤에 배포 그룹에 추가한다.

### 6-2. 단독 Web 인스턴스와 ASG 인스턴스의 이중 매칭

- 요구사항의 `Name=lcamtest-web` 태그를 단독 인스턴스와 ASG 인스턴스가 모두 쓰면, 태그 필터(`Name=lcamtest-web`)가 두 쪽 모두에 일치한다.
- **제안**: Web 배포 그룹의 태그 필터는 `Name`이 아니라 전용 태그 `lc-deploy=web-standalone`을 쓴다. 단독 인스턴스에만 이 태그를 붙이고(`Name=lcamtest-web`도 함께), Launch Template의 태그에는 넣지 않는다. 그러면 ASG 인스턴스는 ASG로만, 단독 인스턴스는 태그로만 일치해 겹치지 않는다. 같은 인스턴스를 한 그룹에 중복 등록하는 문제가 설계상 사라진다.
- Queue·Scheduler 배포 그룹은 `Name=lcamtest-queue|scheduler` 태그를 쓴다. ASG 인스턴스는 이름이 달라 일치하지 않는다.
- 하나의 ASG에 배포 그룹을 여러 개 연결하면 launch 시 배포가 동시에 시작돼 실패할 수 있다는 문서의 주의는 우리에게 해당하지 않는다. ASG에는 `lc-web-dg` 하나만 연결한다([Avoid associating multiple deployment groups with a single Auto Scaling group](https://docs.aws.amazon.com/codedeploy/latest/userguide/troubleshooting-auto-scaling.html)).

### 6-3. 단독 Web 인스턴스를 TG에서 어떻게 정리하나

- 배포가 끝나면 배포 그룹의 **모든 인스턴스가 선택한 TG에 다시 등록**된다([같은 in-place 문서](https://docs.aws.amazon.com/codedeploy/latest/userguide/deployment-groups-create-in-place.html)). TG에서 `deregister-targets`만 하면 다음 배포가 단독 인스턴스를 다시 등록할 수 있다. 문서가 이 경우를 명시하지는 않으므로, 아래 순서로 정리하고 마지막에 한 번 더 배포해 확인한다.
- **제안 순서**: ① ASG 인스턴스 2대 InService + TG healthy 확인 → ② 단독 인스턴스 `deregister-targets` → draining 종료 대기 → ③ 단독 인스턴스 종료 → ④ 배포 그룹에서 태그 필터 제거 → ⑤ 정상 배포 1회로 TG 대상이 ASG 인스턴스 2대뿐인지 확인.
- ④의 CLI 방법(태그 집합을 비우는 인자)은 문서로 확인하지 못했다. 문서는 ASG 목록을 비울 때 `null`이 아닌 빈 리스트를 넘기라고만 설명한다([Troubleshoot Auto Scaling](https://docs.aws.amazon.com/codedeploy/latest/userguide/troubleshooting-auto-scaling.html)). 태그 집합도 같은 규칙인지는 실행 후 `get-deployment-group`으로 확인하고, 안 되면 콘솔로 한다.

### 6-4. §6-3 "수동 모드"의 `Terminate` 중지와 T8·스케일 인 시험

- §6-5는 "T5~T8 통과 후 자동 복구 해제"이므로 T8(`terminate-instance-in-auto-scaling-group --no-should-decrement-desired-capacity`)은 `Terminate`가 중지된 상태에서 하게 된다.
- 문서로 확인된 것: `Terminate`는 스케일 인과 비정상 인스턴스 종료를 막고, `ReplaceUnhealthy`는 `Terminate`에 의존한다([How suspended processes affect other processes](https://docs.aws.amazon.com/autoscaling/ec2/userguide/understand-how-suspending-processes-affects-other-processes.html)). `Terminate`가 중지돼도 `delete-auto-scaling-group --force-delete`는 인스턴스를 종료한다([Considerations for suspending processes](https://docs.aws.amazon.com/autoscaling/ec2/userguide/suspend-resume-considerations.html)). 반면 `terminate-instance-in-auto-scaling-group` 호출이 중지 상태에서 어떻게 동작하는지는 이 문서들에 없다.
- **제안**: 확인된 사실로 단정하지 않고 T8 직전에 호출해 결과를 기록한다. 거부되거나 교체가 안 일어나면 `Terminate`만 재개(나머지는 중지 유지)하고 다시 시험하며, 이 편차를 RESULTS.md에 적는다. 같은 이유로, 시험 사이에 `desired`를 줄여 정리해야 할 때도 `Terminate` 재개가 필요할 수 있다.

### 6-5. 그 밖의 충돌

- **OIDC `sub`와 `environment: production`** (§3 vs §5-2-5): GitHub는 job에 `environment`가 있으면 `sub`를 `repo:<owner>/<repo>:environment:<이름>` 형태로 만들고, 브랜치(`ref:`) 형태는 환경이 없을 때만 쓴다([GitHub OIDC reference](https://docs.github.com/en/actions/reference/security/oidc)). 또한 2026-07-15 이후 만든 저장소는 소유자 ID·저장소 ID가 들어간 형식이 기본이다. 같은 문서. 실제 저장소 설정을 조회하니 `use_immutable_subject=true`, `sub_claim_prefix=repo:hohosungho@282423282/lc-cicd-test@1456165869`였다(`gh api repos/hohosungho/lc-cicd-test/actions/oidc/customization/sub`). 그래서 요구사항 문구의 `repo:<owner>/<repo>:ref:refs/heads/<branch>`는 일치하지 않는다.
  - **제안**: 신뢰 정책의 `sub`를 `repo:hohosungho@282423282/lc-cicd-test@1456165869:environment:production` 한 값으로 한정하고(`aud=sts.amazonaws.com`), GitHub 환경 `production`의 배포 브랜치를 `main`으로 제한한다. 브랜치 한정이라는 요구사항의 의도를 환경 보호 규칙으로 유지한다.
- **T4의 롤백 실패**: 자동 롤백이 켜져 있으면 N+1이 ApplicationStop에서 실패한 뒤 롤백이 N의 고장난 stop.sh를 다시 써서 롤백도 실패할 것으로 예상한다. 이는 §7 중단 기준의 "롤백 실패"와 겹친다. 배포를 만들 때 자동 롤백 설정을 덮어쓸 수 있으므로([Redeploy and roll back](https://docs.aws.amazon.com/codedeploy/latest/userguide/deployments-rollback-and-redeploy.html)) 이 시험은 롤백을 끈 배포로 하고, 의도된 실패임을 기록한다.
- **T15의 "1일 만료"**: S3 수명주기 규칙은 일 단위이고, 만료 시점과 실제 삭제 사이에 지연이 있다([Expiring objects](https://docs.aws.amazon.com/AmazonS3/latest/userguide/lifecycle-expire-general-considerations.html)). 2~3일 시험 안에서 정확한 시점에 재현하기 어렵다. **제안**: 1일 만료 규칙은 요구사항대로 걸어 두고(자연 만료를 관찰), T15 시험 자체는 롤백 대상 zip 1개를 직접 삭제해 만료 상태를 만든다. 두 방법의 결과를 구분해 기록한다.
- **launch deployment 실패 루프**: §6-3 수동 모드에서도 `Launch`는 중지하지 않으므로, launch deployment가 실패하면 ASG가 인스턴스를 계속 다시 띄운다. 4-2장의 규칙(인스턴스 ID 지정 고장만 사용)과 중단 기준으로 막는다.

---

## 7. 네트워크 결정안

- **VPC `lc-vpc` 10.30.0.0/16**을 새로 만든다. 계정에는 기본 VPC(172.31.0.0/16)와 10.100.0.0/16, 10.200.0.0/16 VPC가 이미 있다. 이들은 건드리지 않고 겹치지 않는 대역을 쓴다.
- **public 서브넷 2개만** 둔다: 2a `10.30.1.0/24`, 2c `10.30.2.0/24`. NAT가 없고 모든 인스턴스가 퍼블릭 IP를 쓰는 구성이라 private 서브넷은 쓸 곳이 없다. 요구사항 §3의 "public/private 각 2"는 [변경] 범위 때문에 public 2개로 줄이고, README의 "고객 운영 환경과의 차이"에 적는다. 라우트 테이블 1개(`0.0.0.0/0 → IGW`), S3 게이트웨이 엔드포인트(무료)를 붙인다.
- **보안 그룹**
  - `lc-alb-sg`: 인바운드 80/tcp, 소스 `211.212.235.69/32`만. 아웃바운드는 `lc-ec2-sg`의 80으로만.
  - `lc-ec2-sg`(Web·Queue·Scheduler 공용): 인바운드 80/tcp, 소스 `lc-alb-sg`만. SSH 없음. 아웃바운드는 전체 허용(443 SSM·S3·CodeDeploy, 80 apt). 퍼블릭 IP가 있어도 인바운드는 ALB SG 외에 열리지 않는다.
  - 인터넷 노출은 ALB(내 IP만)뿐이다. HTTPS 인증서는 쓰지 않으므로(HTTP 80) README의 차이 목록에 적는다.
- **Launch Template의 `associate_public_ip_address`**: NAT가 없으므로 ASG 인스턴스도 퍼블릭 IP가 있어야 SSM 에이전트·CodeDeploy 에이전트·S3(CodeDeploy 에이전트 버킷)에 닿는다. Launch Template에서 네트워크 인터페이스를 정의하면 서브넷의 auto-assign 설정을 덮어쓰고, 이때 보안 그룹은 인터페이스 안에 지정해야 한다(템플릿 상위의 SG와 동시 지정 불가). 문서: [Create a launch template for an Auto Scaling group](https://docs.aws.amazon.com/autoscaling/ec2/userguide/create-launch-template.html). 서브넷 설정(`MapPublicIpOnLaunch`)과 Launch Template(`DeviceIndex=0, AssociatePublicIpAddress=true, Groups=[lc-ec2-sg]`)에 **모두 명시**한다. 단독 인스턴스도 같은 값으로 띄운다. 첫 ASG 인스턴스에서 퍼블릭 IP·SSM 연결 여부를 확인해 기록한다.
- **TG 프로파일 A/B(변수화)**: `infra/cli/env.sh`의 `TG_PROFILE=A|B`와 `45-tg-profile.sh`가 값을 적용한다.
  - A(고객 현재값): deregistration delay 300초, 헬스체크 간격 30초, healthy 5, unhealthy 2
  - B(튜닝값): 30초, 10초, healthy 2, unhealthy 2
  - 적용 명령: `modify-target-group-attributes`(`deregistration_delay.timeout_seconds`)와 `modify-target-group`(`--health-check-interval-seconds --healthy-threshold-count --unhealthy-threshold-count`). 헬스체크 타임아웃은 간격보다 짧아야 하므로 5초로 고정한다.
  - A는 healthy 5회 × 30초 = 약 150초가 걸리므로 ASG 헬스체크 유예는 300초로 시작한다(B는 180초). 프로파일 전환은 TG만 바꾸고 배포 그룹은 그대로이므로 T17은 같은 배포를 두 번 돌려 비교한다.

---

## 8. 사용자에게 묻는 질문 (3개)

각 질문에는 제가 기본으로 가정한 안(★)이 있다. 답이 없으면 ★로 진행하지 않고, 승인 때 함께 확정한다.

1. **골든 AMI를 어디서 굽나** (§6-1은 "단독 Web 1대 첫 배포 성공 → 골든 AMI 생성")
   - ★ (a) 별도 builder 인스턴스에서 `provision.sh`로 굽는다. 단독 Web은 그대로 남아 T2~T4와 ASG 전환 비교에 쓰인다. 코드와 `.env`가 AMI에 들어갈 여지가 없다. builder는 1~2시간, 약 $0.03~0.06.
   - (b) 요구사항 문구대로 단독 Web에서 굽는다. 에이전트 정지·코드/`.env` 정리가 필요해 그 인스턴스는 더 이상 Web으로 못 쓰고 폐기한다.
2. **정적 자산(assets 버킷)과 Node 빌드를 둘지** (§3, §5-2-1·2)
   - ★ (a) 둘 다 뺀다. 앱 UI는 인라인 CSS 한 장이고 정적 파일을 CloudFront 없이 인스턴스 nginx가 직접 서빙하므로 assets 버킷이 쓰이지 않는다. 워크플로가 단순해지고 `s3 sync --delete 금지`는 쓸 곳이 없어진다. README 차이 목록에 적는다.
   - (b) 유지한다. 해시 파일 하나를 만들어 assets 버킷에 `--delete` 없이 sync만 시연한다. 워크플로 단계가 늘고 실제 서빙에는 쓰이지 않는다.
3. **공개 저장소에 올라가는 값** (`hohosungho/lc-cicd-test`는 public)
   - ★ (a) 스크립트·워크플로에는 계정 ID와 내 IP를 쓰지 않는다(런타임 조회, git 제외 파일, repository variable). 다만 이미 로컬에 커밋된 `docs/CONTEXT.md`와 이 문서, `docs/STATE.md`에는 계정 ID와 IP가 들어 있다. push 전에 이 세 문서는 값을 가린 사본으로 올리거나 push 대상에서 제외한다.
   - (b) 계정 ID는 비밀이 아니라고 보고 그대로 둔다(내 IP도 포함). 설정이 단순하다.

---

## 승인 내역

(승인 후 작성)

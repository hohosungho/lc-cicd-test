# 콘솔 구성 가이드 (lc CodeDeploy + ASG 데모)

리전 `ap-northeast-2`, 이름 접두사 `lc`. 모든 리소스에 태그 `Project=lcamtest`, `Owner=sungho`, `Ephemeral=true`.
`<ACCOUNT_ID>` = 본인 샌드박스 계정 ID, `<MY_IP>` = 본인 공인 IP. 이 문서는 공개 저장소에 올라가므로 실제 값은 콘솔에만 입력한다.
`.env` 는 이번 데모에서 SSM 을 쓰지 않는다(AfterInstall 이 고정 내용으로 만든다). 그래서 기본 구성에서는 SSM 파라미터 작업이 없다(T7 의 `ssm` 고장 대상 모드를 쓸 때만 3-1 의 선택 항목).

만드는 순서: **1 네트워크 → 2 S3 → 3 IAM → 4 SG → 5 단독 Web+AMI → 6 ALB/TG → 7 CodeDeploy → 8 GitHub → 9 첫 배포 → 10 AMI → 11 ASG**

---
## 1. 네트워크 (VPC > VPC 생성 > "VPC 등" 선택)
| 항목 | 값 |
|---|---|
| 이름 접두사 | `lc` (→ `lc-vpc`) |
| IPv4 CIDR | `10.0.0.0/16` |
| AZ | 2개 (`ap-northeast-2a`, `ap-northeast-2c`) |
| 퍼블릭 서브넷 | 2 |
| 프라이빗 서브넷 | **0** |
| NAT 게이트웨이 | **없음** |
| VPC 엔드포인트 | **S3 게이트웨이** |
- 생성 후 퍼블릭 서브넷 2개 각각: 작업 > 서브넷 설정 편집 > **퍼블릭 IPv4 주소 자동 할당 활성화**.
- 확인: 라우팅 테이블에 `0.0.0.0/0 → igw-…` 와 S3 엔드포인트가 있다.
- (고객 운영과 차이: 운영은 프라이빗 서브넷 + AZ별 NAT 2개)

## 2. S3 (S3 > 버킷 만들기)
- 이름 `lc-deploy-<ACCOUNT_ID>`, 퍼블릭 액세스 모두 차단, 기본 암호화 SSE-S3. (assets 버킷은 이번 데모에서 만들지 않는다)
- 수명 주기 규칙은 T15 때 만든다 (TEST-GUIDE 참고).

## 3. IAM
### 3-1. 인스턴스 역할 `lc-ec2-role` (+ 인스턴스 프로파일 `lc-ec2-profile`, 콘솔이 자동 생성)
- 신뢰: EC2. 관리형 정책 `AmazonSSMManagedInstanceCore`.
- 인라인 정책 `lc-ec2-inline`:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["s3:GetObject", "s3:GetObjectVersion"],
      "Resource": "arn:aws:s3:::lc-deploy-<ACCOUNT_ID>/*" },
    { "Effect": "Allow", "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::lc-deploy-<ACCOUNT_ID>" },
    { "Effect": "Allow", "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": ["arn:aws:s3:::aws-codedeploy-ap-northeast-2", "arn:aws:s3:::aws-codedeploy-ap-northeast-2/*"] }
  ]
}
```
- (선택, T7 의 `fault_target=ssm` 을 쓸 때만) 위 Statement 에 추가:
  `{ "Effect": "Allow", "Action": "ssm:GetParameter", "Resource": "arn:aws:ssm:ap-northeast-2:<ACCOUNT_ID>:parameter/lcamtest/prd/FAULT_INSTANCE_IDS" }`
  그리고 SSM 파라미터 `/lcamtest/prd/FAULT_INSTANCE_IDS` (String, 쉼표 구분 instance-id) 를 만든다. 쓰지 않으면 이 항목은 불필요.
- `codedeploy:*` 는 넣지 않는다(에이전트는 서비스 쪽 폴링에 인스턴스 역할 권한이 필요 없다).

### 3-2. CodeDeploy 서비스 역할 `lc-codedeploy-role`
- 신뢰: `codedeploy.amazonaws.com`. 관리형 정책 `AWSCodeDeployRole`.

### 3-3. GitHub OIDC
- IAM > ID 공급자 > 추가: OpenID Connect, URL `https://token.actions.githubusercontent.com`, 대상 `sts.amazonaws.com`.
- 역할 `lc-github-oidc-role`: 웹 ID, 위 공급자, 대상 `sts.amazonaws.com`. 신뢰 정책에서 `aud` 는 `StringEquals`, `sub` 는 **`StringLike` 로 두 형식을 모두 허용**:
```json
"StringLike": { "token.actions.githubusercontent.com:sub": [
  "repo:hohosungho/lc-cicd-test:ref:refs/heads/main",
  "repo:hohosungho@*/lc-cicd-test@*:ref:refs/heads/main" ] }
```
  이유: GitHub 는 2026-07-15 이후 만든(또는 이름 변경·이전한) 저장소에 `repo:OWNER@OWNER-ID/REPO@REPO-ID:ref:refs/heads/BRANCH` 형식(immutable subject)을 쓴다. 이전 형식은 `repo:OWNER/REPO:ref:refs/heads/BRANCH`. 이 저장소가 어느 쪽인지 몰라도 되도록 둘 다 적었다. 출처: https://docs.github.com/en/actions/reference/security/oidc (Immutable subject claims).
  워크플로는 `environment:` 를 쓰지 않으므로 sub 는 위처럼 `ref:refs/heads/main` 으로 끝난다. 그래도 AssumeRole 이 거부되면 Actions 로그/CloudTrail 에 찍힌 sub 값을 그대로 조건에 넣는다.
- 인라인 정책 `lc-github-deploy`:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["s3:PutObject"], "Resource": "arn:aws:s3:::lc-deploy-<ACCOUNT_ID>/deploy/*" },
    { "Effect": "Allow",
      "Action": ["codedeploy:CreateDeployment", "codedeploy:GetDeployment", "codedeploy:GetDeploymentConfig",
                 "codedeploy:GetApplicationRevision", "codedeploy:RegisterApplicationRevision"],
      "Resource": "*" }
  ]
}
```

## 4. 보안 그룹 (EC2 > 보안 그룹, VPC = `lc-vpc`)
| 이름 | 인바운드 | 아웃바운드 |
|---|---|---|
| `lc-alb-sg` | HTTP 80, 소스 `<MY_IP>/32` | 기본(전체) |
| `lc-ec2-sg` | HTTP 80, 소스 `lc-alb-sg` | 기본(전체). SSH 규칙 **없음** |
- 인스턴스에 퍼블릭 IP 가 붙지만 인바운드는 ALB 에서만 열려 있다. 아웃바운드 443 은 SSM, S3, CodeDeploy 통신에 필요하다.

## 5. 단독 Web 인스턴스 (EC2 > 인스턴스 시작)
| 항목 | 값 |
|---|---|
| 이름 태그 | `Name=lcamtest-web` + 전용 태그 **`lc-deploy=web-standalone`** + 공통 3태그 |
| AMI | Ubuntu Server 24.04 LTS |
| 유형 | t3.small |
| 키 페어 | 없음 |
| 네트워크 | `lc-vpc` 퍼블릭 서브넷(2a), 퍼블릭 IP **활성화**, SG `lc-ec2-sg` |
| 스토리지 | gp3 10GiB, 암호화 |
| IAM 프로파일 | `lc-ec2-profile` |
| 메타데이터 | IMDSv2 **필수**, 홉 제한 **2** |
| 사용자 데이터 | 저장소의 `ami/install.sh` 내용 전체 |
- 확인(세션 관리자 접속): `ami/README.md` 2번 절 명령. 에이전트가 `active`, `/var/log/lc-install.log` 마지막 줄이 "install 완료".
- 전용 태그를 쓰는 이유: 나중에 ASG 인스턴스(Name=lcamtest-web)와 단독 인스턴스가 같은 배포 그룹에 이중 매칭되지 않게 한다.

Queue / Scheduler 도 같은 방식으로 1대씩: 이름 태그 `Name=lcamtest-queue`, `Name=lcamtest-scheduler`, 같은 프로파일·SG·user-data(`install.sh`). (공통 3태그 포함)

## 6. ALB / 타깃 그룹
### 타깃 그룹 `lc-web-tg` (EC2 > 대상 그룹)
| 항목 | 값 |
|---|---|
| 유형 | 인스턴스, HTTP:80, `lc-vpc` |
| 헬스체크 경로 | `/up`, 성공 코드 200 |
| **프로파일 A (고객 현재값)** | 간격 30초, healthy 5, unhealthy 2, 등록 취소 지연 **300초** |
| **프로파일 B (튜닝값)** | 간격 10초, healthy 2, unhealthy 2, 등록 취소 지연 **30초** |
- 처음엔 A 로 만들고 T17 때 B 로 바꿔 소요 시간을 비교한다. 대상은 지금 등록하지 않는다(CodeDeploy 가 등록).
### ALB `lc-alb`
- 인터넷 경계, IPv4, `lc-vpc`, **두 퍼블릭 서브넷**, SG `lc-alb-sg`, 리스너 HTTP:80 → `lc-web-tg`.

## 7. CodeDeploy (Developer Tools > CodeDeploy)
### 애플리케이션 `lc-app` (컴퓨팅 플랫폼 EC2/온프레미스)
### 배포 그룹 3개 (공통: 서비스 역할 `lc-codedeploy-role`, 배포 유형 **현재 위치(in-place)**, 환경 구성 아래, 에이전트 설치 "안 함", 로드 밸런서 항목은 Web 만, 롤백 **배포 실패 시 자동 롤백 사용**)
| 그룹 | 환경 구성 | 배포 설정 | 로드 밸런서 |
|---|---|---|---|
| `lc-web` | Amazon EC2 인스턴스 태그 `lc-deploy = web-standalone` (5번 이후 ASG 로 교체, 11번) | `CodeDeployDefault.OneAtATime` | 사용, `lc-web-tg` |
| `lc-queue` | 태그 `Name = lcamtest-queue` | `CodeDeployDefault.AllAtOnce` | 사용 안 함 |
| `lc-scheduler` | 태그 `Name = lcamtest-scheduler` | `CodeDeployDefault.AllAtOnce` | 사용 안 함 |
- 고급 옵션(Web): "오래된 인스턴스 처리 방식 = **업데이트**(`outdatedInstancesStrategy=UPDATE`)"는 11번에서 ASG 를 연결한 뒤 확인한다.
- 확인: 각 그룹 화면에서 "일치하는 인스턴스" 수가 1.

## 8. GitHub (저장소 `hohosungho/lc-cicd-test`)
Settings > Secrets and variables > Actions > **Variables**:
| 이름 | 값 |
|---|---|
| `AWS_ROLE_ARN` | `lc-github-oidc-role` 의 ARN |
| `AWS_REGION` | `ap-northeast-2` |
| `DEPLOY_BUCKET` | `lc-deploy-<ACCOUNT_ID>` |
| `CD_APPLICATION` | `lc-app` |
| `CD_GROUP_WEB` / `CD_GROUP_QUEUE` / `CD_GROUP_SCHEDULER` | `lc-web` / `lc-queue` / `lc-scheduler` |
| `ASSETS_BUCKET` | 비워 둠 (이번 데모에서 미사용) |
- Actions 탭에서 `deploy` 워크플로가 보이는지 확인.

## 9. 첫 배포
- `main` 에 push 하면 자동 실행(또는 Actions > deploy > Run workflow, `fault=none`).
- CodeDeploy 콘솔 > 배포 > 이벤트 목록을 본다. Web 의 순서: `BeforeBlockTraffic → BlockTraffic → AfterBlockTraffic → ApplicationStop → DownloadBundle → BeforeInstall → Install → AfterInstall → ApplicationStart → ValidateService → BeforeAllowTraffic → AllowTraffic → AfterAllowTraffic`. 첫 배포의 ApplicationStop 은 건너뛴다.
- 성공 후: TG 대상이 `healthy`, `http://<ALB DNS>/` 에서 버전·SHA·instance-id·배경색이 보인다. 인스턴스에서 `ls -l /var/www/current /var/www/releases`.

## 10. 골든 AMI
`ami/README.md` 4~6번 절: 정리 스크립트(`pre-bake-cleanup.sh --yes`) 실행 → 이미지 생성 `lc-web-golden-<yyyymmdd>` (재부팅 안 함 체크 해제) → 사용자 데이터 없이 확인용 인스턴스 하나 띄워 검증 후 종료.
- **정리 스크립트 직후 단독 Web 의 에이전트는 멈춰 있지만, 비활성화(disable)되지는 않는다(enabled 유지).** 그래서 이미지 생성 방식에 따라 다르다.
  - 재부팅하는 기본값(재부팅 안 함 체크 해제): 스냅샷 후 원본 인스턴스가 재부팅하면서 에이전트가 **자동으로 다시 시작**한다. cloud-init 이 첫 부팅 상태라 사용자 데이터(`install.sh`)도 다시 실행된다. 단 앱 코드와 `.env` 는 지워져 있어 `/var/www/current` 가 없으므로 `/up` 이 404 이고 TG 에서 unhealthy 가 된다. 다시 서비스하려면 재배포가 필요하다.
  - `--no-reboot`/재부팅 안 함 체크: 에이전트가 멈춘 채로 남는다. 배포 대상으로 쓰려면 `sudo systemctl start codedeploy-agent`.
  - AMI 에 들어가는 에이전트는 "멈춘 상태 + enabled" 이므로, 이 AMI 로 띄운 새 인스턴스에서는 부팅 때 자동 시작한다.

## 11. ASG (EC2 > Auto Scaling 그룹) — 순서 지킴
1. **시작 템플릿 `lc-web-lt`**: AMI = 골든 AMI, t3.small, IAM 프로파일 `lc-ec2-profile`, 메타데이터 IMDSv2 필수·홉 2, 스토리지 암호화, 사용자 데이터 **없음**, 태그(인스턴스) `Name=lcamtest-web` + 공통 3태그.
   **네트워크 인터페이스를 정의한다면 "퍼블릭 IP 자동 할당 = 활성화"를 반드시 켠다**(템플릿 값이 서브넷 설정을 덮어쓴다. NAT 가 없어 퍼블릭 IP 가 없으면 SSM·CodeDeploy 통신이 전부 막힌다). 인터페이스를 정의하지 않고 보안 그룹은 템플릿의 "보안 그룹" 칸에 `lc-ec2-sg` 로 넣는 쪽이 간단하다.
2. **ASG `lc-web-asg`**: 템플릿 `lc-web-lt`, 두 퍼블릭 서브넷, 기존 로드 밸런서 대상 그룹 `lc-web-tg` 연결, **ELB 헬스 체크 켜기**, 유예 기간 **180~300초**, 크기 **min 0 / desired 0 / max 3**, 스케일링 정책 없음.
3. **수동 모드**: ASG > 고급 구성 > 중지된 프로세스(또는 인스턴스 관리 > 프로세스 일시 중지)에서 `ReplaceUnhealthy`, `Terminate`, `AZRebalance`, `ScheduledActions`, `AlarmNotification` 일시 중지.
4. **CodeDeploy `lc-web` 를 ASG 기준으로 전환**: 배포 그룹 편집 > 환경 구성에서 **Amazon EC2 Auto Scaling 그룹 `lc-web-asg` 선택**, **태그 필터는 제거**, 고급 옵션 "오래된 인스턴스 업데이트" 확인. (ASG 연결 시 CodeDeploy 가 launch 라이프사이클 훅을 만든다. ASG > 인스턴스 관리 > 수명 주기 후크에서 확인)
5. `desired = 1` → ASG 활동 기록에서 인스턴스 시작 → CodeDeploy 배포 목록에 "launch deployment"(생성자 EC2 Auto Scaling)가 자동 생성되는지 확인 → TG `healthy` 후에 트래픽. 이어서 `desired = 2`.
6. 시험 T5~T8 이후 자동 복구 프로세스 일시 중지 해제 → T9~T12. 마지막에 대상 추적 스케일링 정책(CPU 50%) 추가 후 부하로 증설 확인.
7. 단독 Web(`lcamtest-web`, 태그 `lc-deploy=web-standalone`)은 ASG 가 정상 동작하면 종료한다. 그 전에는 `lc-web` 그룹 태그 필터가 없으므로 이 인스턴스는 더 이상 배포 대상이 아니다.

## 비용 (시간당 대략, 서울 리전 온디맨드, 확인 필요)
t3.small 약 $0.026 × (Web 최대 3 + Queue 1 + Scheduler 1) + ALB 약 $0.03 + 퍼블릭 IPv4 $0.005 × 인스턴스 수. 기본 구성(Web 2 + Queue + Scheduler + ALB)은 시간당 약 $0.20 안팎. 시험이 끝나면 `TEARDOWN.md` 대로 내린다. (가격은 변동되므로 AWS 요금 페이지로 확인)

# lcam-cicd-demo
GitHub Actions + CodeDeploy(in-place) + ALB + ASG 구성에서 배포가 어떻게 진행되는지(appspec/훅, 배포 그룹, launch deployment, 롤링/롤백)를 직접 확인하는 데모. 앱은 배포마다 UI(색·버전·SHA·instance-id)가 바뀌는 것만 보여 주는 최소 PHP 앱이다. AWS 리소스는 콘솔에서 직접 만든다.

| 읽을 것 | 내용 |
|---|---|
| `docs/CONSOLE-GUIDE.md` | 콘솔 기준 구성 순서와 값 (여기서 시작) |
| `docs/TEST-GUIDE.md`, `docs/RESULTS.md` | 시험 절차(T1~T17)와 결과 기록 표 |
| `docs/TEARDOWN.md` | 정리 순서와 비용 |
| `docs/PROPOSAL.md` | 초기 설계 메모 (배경 참고용. 구축 절차는 CONSOLE-GUIDE 가 우선) |
| `scripts/README.md` | 훅 흐름, 고장 스위치 사용법, 로그 위치 |
| `ami/README.md` | 골든 AMI 만드는 절차 |

## 구조
- `app/` 최소 PHP 앱 (`/`, `/up`, `/version`) · `appspec.yml` · `scripts/` 훅 · `ami/` AMI 설치·정리 스크립트 · `.github/workflows/deploy.yml`

## 고객 운영 환경과의 차이
| 데모 | 고객 운영 |
|---|---|
| public 서브넷 + 퍼블릭 IP, NAT 없음 | private 서브넷 + AZ별 NAT 2개 |
| NAT 없이 S3 게이트웨이 엔드포인트 | (동일하게 사용 가능) |
| ALB 인바운드 내 IP만 | CloudFront + internal ALB, WAF |
| DB/Redis 없음, `.env` 고정 내용 | RDS(Multi-AZ), ElastiCache, SSM SecureString 으로 `.env` 생성 |
| 최소 PHP 앱 | Laravel (composer, 마이그레이션, 큐/스케줄러) |
| 기본 암호화 | 고객 관리형 KMS |

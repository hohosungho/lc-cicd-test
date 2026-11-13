# lcam-cicd-demo

## 목적
GitHub Actions + CodeDeploy + Auto Scaling Group 구성에서 배포가 어떻게 진행되는지(appspec/훅, 배포 그룹, launch deployment, 롤링/롤백)를 시험하는 데모.

## 구조
- `app/`: 배포 대상 최소 앱 (릴리스마다 UI가 바뀜)
- `infra/cli/`: AWS CLI 구축 스크립트
- `infra/ami/`: 골든 AMI 관련
- `scripts/`: CodeDeploy 훅 및 보조 스크립트
- `.github/workflows/`: GitHub Actions 워크플로
- `docs/`: STATE.md(리소스 기록), CONTEXT.md(전제·정책), evidence/(시험 증적)

## TODO: 고객 운영 환경과의 차이

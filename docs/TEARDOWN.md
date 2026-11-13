# 정리 순서 (콘솔) — 비용은 켜 둔 시간만큼 나간다

1. ASG `lc-web-asg`: 삭제 (인스턴스 함께 종료). 시작 템플릿 `lc-web-lt` 삭제.
2. EC2 인스턴스: `lcamtest-web`(단독), `lcamtest-queue`, `lcamtest-scheduler`, 확인용 인스턴스 종료.
3. ALB `lc-alb` 삭제 → 대상 그룹 `lc-web-tg` 삭제.
4. CodeDeploy: 배포 그룹 3개 → 애플리케이션 `lc-app` 삭제.
5. AMI `lc-web-golden-*` 등록 취소 → 연결된 스냅샷 삭제.
6. S3 `lc-deploy-<ACCOUNT_ID>`: 비우기 → 삭제.
7. VPC `lc-vpc`: 삭제 (서브넷, IGW, S3 엔드포인트, 라우팅 테이블, 보안 그룹 `lc-alb-sg`/`lc-ec2-sg` 함께 정리).
8. IAM: 역할 `lc-ec2-role`, `lc-codedeploy-role`, `lc-github-oidc-role`, (다른 용도가 없으면) OIDC 공급자 삭제.
9. 확인: 태그 편집기에서 `Project=lcamtest` 로 검색해 남은 리소스가 없는지, 퍼블릭 IPv4(탄력적 IP 포함)가 남아 있지 않은지 확인.

비용 대략: 기본 구성(Web 2 + Queue + Scheduler + ALB)이 시간당 약 $0.20 안팎. 하루 켜 두면 약 $5. 가격은 AWS 요금 페이지로 확인.

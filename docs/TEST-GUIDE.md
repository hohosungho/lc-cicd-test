# 시험 절차서 (직접 수행) — 결과는 RESULTS.md 에 기록

공통: 배포는 GitHub Actions > deploy > Run workflow (`fault`, `fault_target` 입력). 확인은 CodeDeploy 콘솔 배포 이벤트, EC2 > 대상 그룹 > 대상, ASG 활동 기록.
연속 요청 도구(롤링 중 5xx 확인):
```bash
while true; do printf '%s ' "$(date +%T)"; curl -s -o /dev/null -w '%{http_code} ' http://<ALB DNS>/version; curl -s http://<ALB DNS>/version | head -c 120; echo; sleep 0.5; done
```
고장 스위치 값/대상은 `scripts/README.md` 참고.

| ID | 시험 | 절차 요약 | 기대 | 어디서 보나 |
|---|---|---|---|---|
| T1 | 정상 배포 | `fault=none` 배포 | 3개 그룹 Succeeded, `/up` 200, TG healthy | 배포 목록, TG 대상 |
| T2 | ValidateService 실패 → 자동 롤백 | `fault=validate_fail` | Failed + 롤백 배포(이전 SHA)로 복귀, 소요 시간 기록 | 배포 > 롤백 배포, `/version` |
| T3 | 훅별 실패 | `before_install_fail`, `after_install_fail`, `validate_fail` 각각 | 모두 이전 상태로 복귀 (`after_install_fail` 은 current 교체 전 실패) | `/var/www/current` 링크 |
| T4 | 이전 리비전 stop 고장 | `scripts/README.md` 의 "T4 재현 순서" | 일반 배포·롤백 실패 → `--ignore-application-stop-failures` 로 복구 | ApplicationStop 이벤트 |
| T5 | desired 0→1 | ASG desired 1 (수동 모드) | launch deployment 성공, healthy 이후에만 트래픽 | ASG 활동, 배포 목록, TG |
| T6 | 2대 롤링 중 연속 요청 | desired 2 상태에서 연속 요청 루프를 켜고 배포 | 5xx 0건, 정상 대상 최소 1 | 루프 출력 |
| T7 | 첫 인스턴스 실패 / 마지막만 실패 | `fault=validate_fail`, `fault_target=instance:<첫 id>` / 마지막 id. 처리 순서를 미리 모르면 `fault_target=ssm` (훅 실패에만 적용, CONSOLE-GUIDE 3-1 선택 항목 필요) | 첫 실패는 Failed+롤백. 마지막만 실패하면 OneAtATime 에서 전체 Succeeded 로 표시되는지 확인 | 배포 상세 > 대상별 상태 |
| T8 | 인스턴스 종료 | `aws autoscaling terminate-instance-in-auto-scaling-group --instance-id <id> --no-should-decrement-desired-capacity` | 교체 + launch deployment 성공, 소요 시간. (수동 모드에서 `Terminate` 를 꺼 뒀다면 동작이 문서에 없으므로 실제로 확인, 필요하면 `Terminate` 만 재개) | ASG 활동 |
| T9 | 배포 중 desired+1 | 배포 진행 중에 desired 증가 | 새 인스턴스가 후속 배포로 최신화(UPDATE) | 배포 목록 |
| T10 | 스케일 인 | desired 감소 | 진행 중 요청이 정상 종료(등록 취소 지연 동안 draining) | 연속 요청 루프, TG draining |
| T11 | 한 AZ 인스턴스 중지 | 한 AZ 의 인스턴스 중지 | 나머지 AZ 가 처리, 교체 | TG, ASG |
| T12 | `/up` 실패 | 서버에서 `sudo touch /var/www/shared/FAULT_UP_500` | ELB 헬스체크 → ASG 교체 (자동 복구 해제 후에만) | TG unhealthy, ASG 활동 |
| T14 | Queue/Scheduler | Queue 배포 중 worker 로그, Scheduler 가 한 대에서만 도는지 | 워커 graceful 종료·재시작, heartbeat 중복 없음 | `/var/www/shared/storage/logs/*.log` |
| T15 | zip 만료 | deploy 버킷에 `deploy/` 만료 1일 규칙 추가 + 해당 zip 직접 삭제 후 롤백/증설 | 어떤 오류인지 기록 (마지막에 규칙 원복) | 배포 상세 오류 |
| T17 | TG 프로파일 A vs B | 같은 배포를 A / B 로 각각 수행 | 인스턴스당·전체 소요 시간 비교 | 배포 이벤트 시각 |

## 롤백 2경로
1. CodeDeploy 롤백(자동/수동): 이전 성공 zip 재배포. 소요 시간 기록.
2. 비상 수동 롤백: 서버에서 `ln -sfn /var/www/releases/<이전 id> /var/www/current && sudo systemctl reload php8.4-fpm`. 이후 ASG 가 새 인스턴스를 띄우면 **어떤 버전이 올라오는지**(마지막 성공 리비전) 기록.

## 중단 기준과 비상 절차
인스턴스가 3회 연속 뜨고 죽음 / 정상 대수 0 이 10분 이상 / 롤백 실패 →
```bash
aws autoscaling suspend-processes --auto-scaling-group-name lc-web-asg --scaling-processes Launch Terminate ReplaceUnhealthy AZRebalance ScheduledActions AlarmNotification
aws deploy stop-deployment --deployment-id <ID> --auto-rollback-enabled
aws autoscaling update-auto-scaling-group --auto-scaling-group-name lc-web-asg --min-size 0 --desired-capacity 0
```

# 시험 결과

## 시험 환경 메모 (2026-11-13 확인)
- CodeDeploy 에이전트: **1.8.1-26** (Ruby 기반). 요구사항은 2.0.x 이상이었으나, 이 계정의 SSM association `CodeDeployDG-abcd-dg`
  (대상 `tag-key=Name`, 14일 주기, `AWS-ConfigureAWSPackage`)가 Name 태그가 있는 인스턴스에 부팅 직후 1.8.1 을 먼저 설치한다.
  `install.sh` 는 이미 설치된 것을 보고 2.x 설치를 건너뛴다. 모든 인스턴스가 1.8.1 로 일정하다는 이유로 이 상태로 시험한다.
- 공식 문서상 Ubuntu 24.04 는 2.0.x 이상에서만 테스트됨, 현재 최소 지원 버전은 2.1.x. 2.x 는 로그에 배포 ID 접두사가 붙는 등 일부 형식이 다르다.
- 고객 운영과 비교할 때 이 차이를 감안한다.

| ID | 일시 | 수행 내용 | 기대 | 실제 | 소요 시간 | 증빙(배포 ID, 명령 출력) |
|---|---|---|---|---|---|---|
| T1 | | | | | | |
| T2 | 2026-11-15 22:49~22:54 | `fault=validate_fail`, `fault_target=all`, `release_tag=t2-fail` 로 Run workflow (커밋 `ab876e0`). Web 2대(2a·2c) healthy 상태, 0.5초 간격 연속 요청 | Failed → 자동 롤백으로 이전 성공 리비전 복귀 | 세 그룹 모두 Failed → `codeDeployRollback` 배포 Succeeded, 리비전 `10ec7ba` 로 복귀. 연속 요청 959건 전부 200, 5xx 0건, 응답 sha 전부 `10ec7ba` | 고장 배포 49초, 롤백 3분 24초, 실패 시작~복구 약 4분 14초 (Web) | 아래 "T2 상세" |
| T3 | | | | | | |
| T4 | | | | | | |
| T5 | | | | | | |
| T6 | | | | | | |
| T7 | | | | | | |
| T8 | | | | | | |
| T9 | | | | | | |
| T10 | | | | | | |
| T11 | | | | | | |
| T12 | | | | | | |
| T14 | | | | | | |
| T15 | | | | | | |
| T17 | | | | | | |
| 롤백 ① CodeDeploy | | | | | | |
| 롤백 ② 수동 current | | | | | | |

## T2 상세 — ValidateService 실패 → 자동 롤백 (2026-11-15)

**사전 상태**
- 마지막 성공 배포: `lc-web` `d-ZOW42OJXL`, `lc-queue` `d-WURABRJXL`, `lc-scheduler` `d-Z3RMMGJXL` (모두 리비전 `deploy/10ec7ba….zip`)
- ASG `lc-web-asg` desired 2 (`i-053f9bd38658e9606` 2c, `i-08db704706f8a24d0` 2a), 수동 모드(5개 프로세스 일시 중지)
- 대상 그룹: 등록 취소 지연 30초, 헬스체크 30초 × healthy 5 / unhealthy 2
- 고장 zip 이 정상 zip(`10ec7ba`)을 덮어쓰지 않도록 문서 전용 커밋(`ab876e0`)을 먼저 push (워크플로가 `deploy/<SHA>.zip` 키를 쓰기 때문)

**배포 ID**

| 그룹 | 고장 배포 (user) | 결과 | 롤백 배포 (codeDeployRollback) | 결과 |
|---|---|---|---|---|
| lc-web | `d-I4PU70UXL` 22:49:55 → 22:50:44 | Failed (`HEALTH_CONSTRAINTS`) | `d-ZHSI9ETXL` 22:50:45 → 22:54:09 | Succeeded |
| lc-queue | `d-HFWA19TXL` | Failed | `d-297KDZTXL` | Succeeded |
| lc-scheduler | `d-K76NIUTXL` | Failed | `d-X14EC4TXL` | Succeeded |

**lc-web 고장 배포의 인스턴스별 이벤트 (`d-I4PU70UXL`)**
- `i-053f9bd38658e9606`: BlockTraffic 22:49:58 → 22:50:34 (36초, 등록 취소 지연 30초) → ApplicationStop ~ ApplicationStart 성공 (약 8초) → **ValidateService Failed** (22:50:43, 고장 스위치가 재시도 전에 바로 실패) → BeforeAllowTraffic / AllowTraffic Skipped
- `i-08db704706f8a24d0`: 전 단계 Skipped (OneAtATime 에서 첫 인스턴스가 실패하면 나머지는 진행하지 않음)
- 롤백 배포 `d-ZHSI9ETXL`: `i-053f9bd38658e9606` Succeeded, `i-08db704706f8a24d0` Skipped (이미 `10ec7ba` 상태라 대상에서 제외된 것으로 보임, 미확인)

**연속 요청 (`/version`, 0.5초 간격, 22:49:27 ~ 22:58:21)**
- 959건 전부 HTTP 200, 5xx·타임아웃 0건
- 응답 sha 전부 `10ec7ba` — 고장 리비전은 사용자에게 노출되지 않음. ValidateService 가 AllowTraffic(대상 그룹 재등록) 이전 단계라서, 실패한 서버는 트래픽을 다시 받지 않았고 나머지 1대가 계속 서비스함

**사후 상태**
- `lc-web` lastSuccessfulDeployment = `d-ZHSI9ETXL` (리비전 `10ec7ba`), 대상 2대 healthy
- S3 `deploy/` 에 `e0a541d`, `10ec7ba`, `ab876e0`(고장 zip) 3개 존재
- GitHub Actions run `43721028080` 은 failure 로 표시 (의도된 결과)

**관찰과 메모**
- 실패 코드는 스크립트 오류가 아니라 `HEALTH_CONSTRAINTS` 로 표시됨. 원인 파악은 인스턴스별 이벤트(ValidateService Failed)와 서버의 에이전트 로그로 해야 함
- 롤백은 "복원"이 아니라 이전 리비전의 **새 배포**이므로 BlockTraffic → 설치 → AllowTraffic(healthy 대기) 를 다시 거친다. 그래서 롤백(3분 24초)이 고장 배포(49초)보다 길다. healthy 대기(30초 × 5회)를 줄이면 롤백도 짧아진다
- 재시도를 소진하는 실패(`up500`, 약 30초 이상)의 소요 시간은 T3 에서 확인


# PostgreSQL / PostGIS 준비 모듈

DB 전용 서브넷에 RDS PostgreSQL 17을 생성합니다. PostGIS와 역할 생성은 [초기화 절차](../../docs/database-initialization.md)의 별도 작업입니다. Terraform은 SQL이나 secret value 조회를 실행하지 않습니다.

- 개발 기본값: db.t4g.small, Single AZ, gp3 20GiB → 최대 100GiB, 백업 7일.
- 공개 접근 없음. 기존 database SG로 application SG의 TCP 5432만 허용합니다.
- 저장 암호화, rds.force_ssl=1, 삭제 보호와 최종 스냅샷을 사용합니다. 기본 최종 스냅샷 이름이 이미 있으면 의도적 제거 전에 고유 이름으로 변경합니다.
- 엔진 17은 AWS가 최근 minor로 해석합니다. 17.x로 초기 minor 지정도 가능하며 리전 제공 버전·instance class를 적용 전에 확인합니다. Major 자동 업그레이드는 끄고 minor 자동 업그레이드는 켭니다.
- 관리자 비밀번호는 RDS/Secrets Manager가 관리합니다. 앱/migration secret은 metadata만 생성합니다. secret version, password 변수, secret value data source가 없으므로 비밀번호를 Terraform 상태에 넣지 않습니다.
- 관리자: PostGIS·계정 준비 / migrator: DDL·데이터 적재 / app: 현재 경로 API의 SELECT. 쓰기 기능을 추가할 때 권한을 확장합니다.

bootstrap_config 출력은 endpoint·역할 이름·secret ARN만 포함합니다. secret_policy_arns.bootstrap은 초기화 task role에, application/migration 정책은 각 ECS execution role에 연결합니다. ECR·로그 권한과 실제 task/service는 후속 ECS 모듈 범위입니다.

server_task_configuration은 환경 변수와 Secrets Manager JSON-key selector입니다. 앱은 Flyway를 끄고 migration은 같은 이미지에 SPRING_MAIN_WEB_APPLICATION_TYPE=none, SPRING_FLYWAY_ENABLED=true를 설정합니다. JSON-key 주입은 Fargate Linux platform 1.4.0 이상을 사용합니다.

기본 AWS 관리 키를 사용합니다. 고객 관리 KMS 키를 도입하면 IAM과 키 정책에 kms:Decrypt 권한을 함께 추가합니다. 앱/migrator secret 자동 회전은 아직 구성하지 않았으며 RDS 관리자 secret의 관리형 회전과 구분합니다.

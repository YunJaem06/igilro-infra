# RDS/PostGIS와 Flyway 초기화

개발 DB 최초 준비와 배포 전 migration을 분리합니다. 실제 AWS 적용 전 계정·리전·예산과 Terraform plan을 검토합니다. 이 구현에서는 실제 자원을 생성하지 않았습니다.

## 실행 순서와 권한

1. 기존 bootstrap 상태 저장소와 dev 원격 backend를 준비합니다.
2. network/ECR/database plan을 검토하고 적용합니다. RDS가 available이 될 때까지 기다립니다.
3. 초기화 작업이 관리자 secret으로 PostGIS와 DB 역할을 준비합니다.
4. migration secret을 사용하는 일회성 작업으로 배포 대상 서버와 동일한 JAR/이미지의 Flyway를 실행합니다.
5. exit 0 확인 후 앱 secret만 사용하는 서버를 시작/갱신합니다.
6. OSM·건물 적재는 migrator 계정의 별도 비웹 작업으로 수행합니다.

| 실행 주체 | DB 권한 | Secret 권한 |
| --- | --- | --- |
| 초기화 작업 | 관리자, PostGIS·역할 준비 | 관리자/두 역할 조회, 두 역할 secret 최초 저장 |
| migration/import | public DDL·소유 테이블 변경 | migration secret 조회 |
| 앱 | CONNECT, public USAGE, 테이블 SELECT | application secret 조회 |

작업은 VPC application 서브넷·SG 또는 VPN 등 DB 사설망 경로가 있는 호스트에서 실행합니다. DB는 인터넷에 공개하지 않습니다. Secrets Manager HTTPS에는 기존 NAT 경로를 사용합니다. [ECS 배포 파이프라인](ecs-deployment.md)은 출력된 정책 ARN·환경·secret selector를 연결해 private Fargate task로 실행합니다. 아래 독립 실행 도구는 사설망 경로가 있는 운영 호스트에서도 사용할 수 있습니다.

RDS 관리자는 rds_superuser 권한을 사용하며 진짜 PostgreSQL superuser로 가정하지 않습니다. PostGIS는 관리자가 설치하고 Flyway 테이블 권한은 소유자인 migrator로 설정합니다. V1의 CREATE EXTENSION IF NOT EXISTS는 사전 설치된 확장을 재사용합니다. V1~V3 SQL은 서버 저장소가 소유하며 복제하지 않습니다.

## 연결 metadata와 초기화

아래는 저장소 루트에서 실행하는 macOS/Linux 예시입니다. AWS CLI SSO/역할 프로필과 사설망 경로를 먼저 준비합니다. 리전 엔진·class 가용성은 describe-db-engine-versions, describe-orderable-db-instance-options로 확인합니다.

```bash
export AWS_PROFILE=igilro-dev
aws sts get-caller-identity
terraform -chdir=environments/dev output -json database_bootstrap > database-bootstrap.json
terraform -chdir=environments/dev output -json database_secret_policy_arns
terraform -chdir=environments/dev output -json database_server_tasks
python3 -m venv .venv
.venv/bin/python -m pip install -r scripts/requirements-database.txt
.venv/bin/python scripts/bootstrap_database.py \
  --config database-bootstrap.json \
  --ssl-root-cert docker/database-bootstrap/rds-ca.crt
```

Python 3.12 이상을 사용합니다. JSON은 비밀번호 없는 endpoint·역할·ARN입니다. SDK는 실행 주체의 SSO/role/task 자격 증명을 사용하며 비밀번호를 argv·파일·로그에 출력하지 않습니다. 공식 서울 리전 RDS CA로 verify-full을 사용하므로 실제 RDS DNS 이름을 유지해야 합니다. CA 갱신 시 서버와 초기화 이미지의 인증서를 함께 갱신합니다.

초기화는 DB advisory lock으로 직렬화합니다. 기존 role secret의 endpoint/DB/사용자가 다르면 덮어쓰지 않고 실패합니다. 값이 없는 역할 secret에만 강한 비밀번호를 생성하며 재실행에서는 같은 값을 사용합니다. SQL에는 plaintext 대신 SCRAM verifier를 전달합니다. 기존 역할에 관리자급 권한/멤버십이 있으면 실패합니다.

Secret 저장과 SQL은 분산 트랜잭션이 아닙니다. 값 저장 후 SQL 실패 시 secret을 삭제/회전하지 말고 원인을 해결한 뒤 재실행합니다. 같은 값으로 DB 역할을 맞출 수 있습니다. 초기화와 수동 비밀번호 변경/회전을 동시에 실행하지 않습니다.

초기화 컨테이너:

```bash
docker build -t igilro-database-bootstrap:local -f docker/database-bootstrap/Dockerfile .
docker run --rm igilro-database-bootstrap:local --help
```

ECS 모듈은 DATABASE_BOOTSTRAP_CONFIG 환경으로 database_bootstrap JSON과 bootstrap task role 정책을 주고, command를 다음과 같이 설정합니다.

```json
["--config-env", "DATABASE_BOOTSTRAP_CONFIG", "--ssl-root-cert", "/app/certs/rds-ca.pem"]
```

## 일회성 Flyway

Java 21, 동일 배포 아티팩트와 사설망 경로가 있는 호스트에서:

```bash
.venv/bin/python scripts/run_flyway.py \
  --config database-bootstrap.json \
  --ssl-root-cert docker/database-bootstrap/rds-ca.crt \
  --server-jar /workspace/igilro-server/build/libs/igilro-server-0.0.1-SNAPSHOT.jar
```

도구는 migration secret을 메모리에서 읽어 자식 Java 환경에 주입하고 Flyway 종료 상태를 반환합니다. 비밀번호를 argv/파일에 넣지 않으며 출력에서도 제거합니다. 실패하면 앱 갱신을 중단하고 DB·migration 로그를 확인합니다. 자동 repair/baseline/clean은 하지 않습니다.

ECS는 별도 래퍼 없이 동일한 서버 이미지 digest와 database_server_tasks.migration의 환경·secret selector로 일회성 task를 실행합니다. non-web Spring Boot가 Flyway 후 종료됩니다. 앱은 database_server_tasks.application으로 실행하며 Flyway를 끕니다. 서버 prod 기본값도 Flyway 비활성화입니다. migration secret 읽기 정책은 해당 execution role에만 연결합니다.

JDBC는 sslmode=verify-full과 /app/certs/rds-ca.pem을 사용하며 서버 이미지에 CA를 포함합니다. JSON-key 주입은 Fargate Linux platform 1.4.0 이상, image/task CPU 아키텍처도 일치시킵니다.

## 검증과 운영 경계

- 초기화: ready와 postgisVersion.
- migration: exit 0, Flyway V3, 재실행 시 추가 migration 없음.
- 앱: /api/v1/health 200/UP, CREATE/INSERT/DELETE 불가.
- 그래프 미적재: 경로 API 503 ROUTING_DATA_UNAVAILABLE. 적재 후 실제 경로를 별도 검증합니다.
- 관리자 secret은 RDS 관리형입니다. 앱/migrator 자동 회전은 후속 범위이며 DB 변경과 새 task 배포를 함께 설계합니다.
- 삭제 보호·최종 스냅샷을 사용합니다. 의도적 제거 전에 고유 스냅샷 이름과 복구 가능 여부를 확인합니다.

로컬 테스트:

```bash
terraform fmt -check -recursive
# 각 구성: init -backend=false -lockfile=readonly, validate, test
.venv/bin/python -m unittest discover -s scripts/tests -v
docker build -t igilro-postgis:test -f tests/postgis/Dockerfile .
# 서버 저장소에서 ./gradlew bootJar 선행
DATABASE_TEST_IMAGE=igilro-postgis:test \
IGILRO_SERVER_JAR=../igilro-server/build/libs/igilro-server-0.0.1-SNAPSHOT.jar \
  .venv/bin/python -m unittest discover -s tests/integration -v
```

CI는 모의 AWS provider와 임시 TLS PostGIS를 사용합니다. 서버 계약 checkout ref는 workflow에 고정하며 서버 migration 변경 시 함께 갱신합니다. 실제 AWS 권한·가용 버전·RDS 설치·원격 task 실행은 적용 후 추가 검증합니다.

참고: [RDS PostGIS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.PostgreSQL.CommonDBATasks.PostGIS.html), [RDS secret](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-secrets-manager.html), [RDS TLS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.Concepts.General.SSL.html), [ECS secret](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/secrets-envvar-secrets-manager.html).

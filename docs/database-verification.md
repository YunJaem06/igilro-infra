# RDS/PostGIS 준비 구현 검증 — 2026-10-24

Mac Apple Silicon, Terraform 1.17.0 / AWS provider 6.70.0, Python 3.12.14, Java 21, PostgreSQL 17.11/PostGIS 3.6.4에서 확인했습니다. 실제 AWS 계정·원격 backend·RDS에 접속하지 않았습니다.

## Terraform

- fmt와 bootstrap/network/ecr/database/dev의 init(-backend=false, -lockfile=readonly), validate 성공.
- AWS mock 테스트 13개: bootstrap 2, network 4, ecr 1, database 5, dev 1.
- RDS 공개 접근 차단·암호화·강제 TLS·백업·삭제 보호·최종 스냅샷·RDS 관리형 비밀번호 설정 확인.
- bootstrap 쓰기 대상이 두 역할 secret으로 제한되고 app/migration 읽기 권한이 분리됨을 검증.
- 잘못된 PostgreSQL major, 단일 subnet, 백업 비활성화, storage ceiling 거부.
- Terraform은 비밀번호 변수/secret version/value data source를 사용하지 않음. SQL은 별도 도구가 수행.

## 초기화와 실제 Flyway

Python 단위 8개, 임시 TLS PostGIS 통합 7개 모두 성공했습니다. 실패·오류·건너뜀은 0개입니다.

- secret 최초 생성과 재사용, endpoint/DB/역할 불일치 거부, AccessDenied를 빈 secret으로 처리하지 않음.
- Java argv에 비밀번호가 없고 비정상 종료 상태를 유지하며 출력에서 비밀번호 제거.
- TLS verify-full 연결과 잘못된 CA 거부.
- PostGIS 설치 후 migrator가 실제 서버 JAR의 Flyway V1~V3를 실행하고 다시 실행해 추가 변경 없음.
- 초기화를 재실행해도 secret 값 유지. 앞으로 생성하는 테이블도 앱 SELECT 가능.
- 앱 CREATE TABLE/CREATE SCHEMA/INSERT/DELETE 거부, 과도한 역할 권한·앱 소유 객체 거부.
- PostGIS만 사전 설치한 일반 CREATEROLE 관리자도 초기화/재초기화 성공. RDS의 rds_superuser 동작 전체를 재현한 것은 아니므로 실제 RDS 확인은 별도.
- Flyway history 읽기 권한조차 없는 앱 계정으로 prod 서버를 기동해 health 200/UP. 그래프 미적재 경로는 503 ROUTING_DATA_UNAVAILABLE.

테스트는 기존 개발 DB와 분리한 임시 컨테이너·인증서·임의 포트를 사용하고 종료 시 정리했습니다. 실제 비밀값 대신 메모리의 Secrets Manager fake를 사용했습니다. 실제 Secrets Manager IAM, RDS 가용 버전·class·관리형 secret, private task 실행은 AWS 적용 후 확인해야 합니다.

## 이미지와 서버

- Python bootstrap 이미지를 ARM64로 빌드하고 --help 및 UID/GID 10001 실행 확인.
- Java 서버 이미지를 ARM64로 빌드. 공개 서울 리전 CA를 포함하고 prod 자동 Flyway를 비활성화.
- 공식 CA bundle SHA256: 913fb5b814f17af79d4c1622584a8d0ceddf5b0d76fe353d0c7d1186cdd6b229. 인증서는 비밀키가 없는 공개 파일이며 서버·bootstrap 이미지가 같은 bundle을 사용.
- 서버 clean build 성공: JVM 단위·아키텍처/API 62개, PostGIS 통합 26개, 총 88개 통과.

CI에 database mock 테스트, Python 단위·TLS/Flyway 통합 테스트와 bootstrap 이미지 빌드를 추가했습니다. 서버 계약 ref는 4c450655bd089011b02a952dbce03d2955191999로 고정합니다. 푸시 후 GitHub Actions에서 동일한 검증을 실행합니다.

ECS task/service·ALB·HTTPS·이미지 배포·OIDC와 실제 AWS 적용은 다음 단계입니다. 초기화 작업과 배포할 서버는 같은 migration 버전·이미지 digest를 사용해야 합니다. 앱/migrator 자동 비밀번호 회전은 후속 범위입니다.

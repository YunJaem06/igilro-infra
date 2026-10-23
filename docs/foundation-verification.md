# 인프라 기반 검증 기록

검증일: 2026-10-23 (Asia/Seoul). 실제 AWS 자원을 생성하지 않은 로컬 검증입니다.

## Terraform

- CLI: Terraform 1.17.0, Windows AMD64. 공식 배포 파일의 SHA256을 확인했습니다.
- provider: hashicorp/aws 6.70.0. HashiCorp 서명을 확인하고 Windows AMD64/Linux AMD64 체크섬을 잠금 파일에 기록했습니다.
- `terraform fmt -check -recursive` 통과.
- bootstrap, network, ecr, dev의 `terraform validate` 통과.
- `terraform test`의 AWS 모의 provider 테스트 8개 통과, 실패 0개.

| 구성 | 테스트 | 확인 사항 |
| --- | --- | --- |
| bootstrap | 2개 | 버전 관리·암호화·공개 차단·TLS 강제, 잘못된 계정 입력 거부 |
| network | 4개 | 사설 앱/DB 분리, SG 기반 접근, NAT/S3 경로, AZ별 NAT 전환, 중복 AZ·작은 CIDR 거부 |
| ecr | 1개 | 태그 변경 금지, push 검사, 암호화, 태그가 있는 롤백 이미지 보존 |
| dev | 1개 | 네트워크 출력과 개발 ECR 모듈 연결 |

실제 입력 파일·backend·state·plan·IDE 파일이 Git에서 제외되고, 잠금 파일과 예시는 포함되는 것을 확인했습니다. 테스트에서 사용하는 `apply`는 mock provider에서만 동작합니다.

## 서버 컨테이너

같은 작업에서 `igilro-server`에 추가한 Dockerfile을 Docker Desktop Linux AMD64 환경에서 검증했습니다.

- Java 21 JDK → JRE 다단계 이미지 빌드 통과. 실행 Java는 Temurin 21.0.12.1입니다.
- 임시 Docker 네트워크와 새로운 PostGIS 컨테이너를 사용했습니다. 기존 개발 DB는 사용하지 않았습니다.
- 이미지 기본 `prod` 프로필로 시작하고 UID 10001로 실행되는 것을 확인했습니다.
- 새 DB에 Flyway V1/V2/V3가 모두 성공했습니다.
- `/api/v1/health`: HTTP 200, `status: UP`.
- 잘못된 JSON 요청: HTTP 400, `INVALID_REQUEST`, `application/json`과 requestId 헤더/본문 일치.
- 그래프 미적재 경로 요청: HTTP 503, `ROUTING_DATA_UNAVAILABLE`.
- prod `/v3/api-docs`: HTTP 404.
- 호스트 공개 포트는 localhost의 임의 앱 포트만 사용했습니다. 관리 포트 8081은 공개하지 않았습니다.
- SIGTERM 종료가 제한 시간 안에 완료됐습니다. 임시 컨테이너·볼륨·네트워크는 정리했습니다.

전체 재점검에서 Java 21로 `clean build`를 실행했습니다. 단위·아키텍처·API 테스트 62개와 실제 PostGIS 통합 테스트 26개, 총 88개가 통과했으며 실패·오류·건너뜀은 모두 0개입니다. 기존 CI의 전체 테스트 단계 뒤에 컨테이너 이미지 빌드를 추가했습니다. GitHub workflow의 원격 실행은 아직 확인하지 않았습니다.

## 전체 재점검

- Terraform fmt, 4개 구성의 init/validate와 AWS 모의 테스트 8개를 다시 통과했습니다.
- 실제 AWS provider의 계획 검증도 임시 복사본에서 통과했습니다. 실제 자격 증명을 읽지 않고 더미 값, 빈 AWS 설정, 닫힌 로컬 서비스 endpoint를 사용했으며 원격 backend와 refresh는 사용하지 않았습니다. 계획된 생성 수는 bootstrap 6개, dev 38개입니다. 실제 자원은 생성하지 않았습니다.
- 오프라인 계획 JSON에서 외부 수신 규칙이 ALB의 TCP 80/443 두 개뿐이고, 앱·DB는 별도 SG 참조를 사용하며, SSH/관리 포트가 열리지 않았음을 확인했습니다.
- 서버 이미지를 다시 확인하고 컨테이너 검증을 반복했습니다. 임시 DB 중단 시 health 503, DB 복구 후 서버 재시작 없이 health 200으로 회복했습니다.
- actionlint 1.7.12로 두 저장소의 GitHub Actions 설정이 통과했습니다. 선택적 외부 shellcheck/pyflakes 검사는 실행하지 않았습니다.
- PowerShell에서 `-out=파일.tfplan`과 `-backend-config=backend.hcl`이 점 앞뒤로 분리되는 오류를 재현했습니다. README의 옵션 전체를 따옴표로 감싸도록 수정했습니다.
- 위 수정 외에 현재 1차 구현 범위에서 추가 오류는 발견하지 못했습니다.

## 남은 실제 배포 검증

AWS 계정 권한, AZ 가용성, 서비스 할당량, 비용과 실제 계정에서의 원격 상태·plan/apply는 확인하지 않았습니다. RDS/PostGIS 권한·TLS, ECS 실행, ALB/도메인/HTTPS, 비밀값과 로그, OIDC 배포는 다음 단계입니다. 실제 OSM·건물 자료는 적재하지 않았습니다.

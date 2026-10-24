# 이길로 인프라

이길로 서버의 AWS 인프라를 Terraform으로 관리합니다. 서버 코드와 컨테이너 빌드는 [igilro-server](https://github.com/YunJaem06/igilro-server)에서 관리합니다.

## 구현 범위

첫 단계인 개발 환경의 기반 코드를 구현했습니다. 실제 AWS 자원은 아직 생성하지 않았습니다.

| 구성 | 상태 |
| --- | --- |
| 상태 저장소 | S3 버전 관리, AES256 암호화, 공개 접근 차단, TLS 강제, 삭제 보호 |
| 개발 네트워크 | 전용 VPC, 2개 AZ, 공개/앱/DB 서브넷, NAT, S3 gateway endpoint |
| 접근 규칙 | 인터넷 → ALB 80/443 → 앱 8080 → DB 5432, 관리 포트 8081 차단 |
| 서버 이미지 저장소 | 환경별 ECR, 태그 변경 금지, push 검사, 태그 없는 이미지 정리 |
| 로컬/CI 검증 | Terraform fmt/validate, AWS 모의 provider 테스트 |
| 다음 단계 | RDS/PostGIS, ECS, ALB, 도메인/HTTPS, 비밀값과 로그, OIDC 배포 |

ALB·ECS·RDS는 아직 생성하지 않습니다. 네트워크 모듈은 다음 단계가 연결할 서브넷과 보안 그룹을 준비합니다. 아직 API 접속 주소가 출력되지 않는 것이 정상입니다.

## 구조

```text
bootstrap/                   # 공용 Terraform 상태 저장소
environments/dev/            # 개발 환경 조합, 독립된 상태 파일
modules/network/             # VPC, 서브넷, 라우팅, 보안 그룹
modules/ecr/                 # 서버 이미지 저장소
.github/workflows/terraform.yml
```

Terraform은 `.terraform-version`에 지정한 1.17.0으로 검증합니다. 코드의 최소 버전은 S3 네이티브 잠금을 지원하는 1.10이며, AWS provider는 6.x입니다. `.terraform.lock.hcl`은 각 검증 디렉터리에 포함하며 macOS ARM64(Apple Silicon), Windows AMD64, Linux AMD64 체크섬을 기록합니다. provider 변경은 `init -upgrade` 후 의도적으로 검토합니다.

## AWS 없이 검증

provider 다운로드를 위한 인터넷 연결과 Terraform만 필요합니다. AWS 자격 증명은 필요하지 않습니다.

```powershell
terraform fmt -check -recursive
$directories = @('bootstrap', 'modules/network', 'modules/ecr', 'environments/dev')
foreach ($directory in $directories) {
    terraform "-chdir=$directory" init -backend=false -input=false -lockfile=readonly
    if ($LASTEXITCODE -ne 0) { throw "init failed: $directory" }
    terraform "-chdir=$directory" validate
    if ($LASTEXITCODE -ne 0) { throw "validate failed: $directory" }
    terraform "-chdir=$directory" test -no-color
    if ($LASTEXITCODE -ne 0) { throw "test failed: $directory" }
}
```

테스트는 `mock_provider "aws"`만 사용합니다. 테스트의 `command = apply`는 모의 provider의 가상 상태만 변경하며 AWS API를 호출하거나 자원을 만들지 않습니다. 기본 상태 보호, 사설 네트워크 경계, NAT 모드 전환, 입력 검증과 개발 환경 연결을 확인합니다. 실제 AWS 권한·리전 가용성·할당량·배포 성공까지 보장하지는 않습니다.

CI는 동일한 검증만 실행합니다. AWS 인증, 실제 plan/apply, 이미지 push와 배포는 아직 자동화하지 않습니다.

## 실제 적용 준비

다음 절차는 계정과 리소스를 확인한 뒤 수동으로 실행합니다. 이 코드 작성 과정에서는 실행하지 않았습니다. NAT Gateway, 공인 IPv4, S3, ECR 등은 실제 생성·사용 시 요금이 발생합니다.

AWS CLI v2의 SSO 또는 역할 기반 프로필을 준비합니다. 저장소에 access key를 적지 않습니다.

```powershell
$env:AWS_PROFILE = 'igilro-dev' # 먼저 본인 계정에 이 프로필을 구성합니다.
aws sts get-caller-identity
Copy-Item bootstrap/terraform.tfvars.example bootstrap/terraform.tfvars
```

`bootstrap/terraform.tfvars`의 예시 계정 ID를 위 명령의 실제 계정으로 바꿉니다. `allowed_account_ids`로 다른 계정에 대한 실수 적용을 막습니다. S3 버킷 이름은 `igilro-tfstate-<account-id>-ap-northeast-2` 형식입니다. 같은 이름의 버킷을 이미 관리하고 있다면 새로 적용하기 전에 소유권과 기존 상태를 확인합니다.

PowerShell에서는 점이 포함된 옵션 값을 하나의 인자로 전달하도록 `"-out=bootstrap.tfplan"`, `"-backend-config=backend.hcl"`처럼 옵션 전체를 따옴표로 감쌉니다.

### 1. 상태 저장소 생성

최초 bootstrap은 로컬 상태로 시작합니다. 생성 직후 로컬 상태 파일을 안전하게 보관하고, 아래 원격 이전을 마칠 때까지 삭제하지 않습니다.

```powershell
terraform -chdir=bootstrap init
terraform -chdir=bootstrap plan "-out=bootstrap.tfplan"
terraform -chdir=bootstrap apply bootstrap.tfplan
terraform -chdir=bootstrap output
```

`bootstrap/backend.hcl.example`을 `backend.hcl`로 복사하고 계정·버킷 값을 바꿉니다. `bootstrap/backend.tf.example`을 `backend.tf`로 복사한 뒤 bootstrap 자신의 상태도 방금 만든 버킷으로 이전합니다.

```powershell
Copy-Item bootstrap/backend.hcl.example bootstrap/backend.hcl
Copy-Item bootstrap/backend.tf.example bootstrap/backend.tf
# backend.hcl의 계정과 버킷 이름을 수정한 다음 실행합니다.
terraform -chdir=bootstrap init -migrate-state "-backend-config=backend.hcl"
terraform -chdir=bootstrap state list
```

`bootstrap/backend.tf`는 최초 생성 순환 의존성을 피하기 위한 로컬 설정입니다. 다른 컴퓨터에서는 기존 bootstrap 상태를 사용할 때 위 예시 파일들을 먼저 준비하고 `init "-backend-config=backend.hcl"`로 연결합니다. 이미 생성된 버킷에 새 로컬 상태로 `apply`하지 않습니다.

### 2. 개발 네트워크와 ECR 생성

```powershell
Copy-Item environments/dev/terraform.tfvars.example environments/dev/terraform.tfvars
Copy-Item environments/dev/backend.hcl.example environments/dev/backend.hcl
# 두 파일 모두 실제 계정으로 수정하고, backend 버킷은 bootstrap 출력과 맞춥니다.
terraform -chdir=environments/dev init "-backend-config=backend.hcl"
terraform -chdir=environments/dev plan "-out=dev.tfplan"
terraform -chdir=environments/dev apply dev.tfplan
terraform -chdir=environments/dev output
```

상태 경로는 bootstrap과 dev가 각각 `bootstrap/terraform.tfstate`, `dev/terraform.tfstate`로 다릅니다. 둘 다 `use_lockfile = true`로 S3 잠금을 사용합니다. 별도 DynamoDB 잠금 테이블은 만들지 않습니다. 백엔드 역할에는 대상 경로의 ListBucket/GetObject/PutObject와 `.tflock` 객체의 GetObject/PutObject/DeleteObject 권한이 필요합니다. 상태 파일 삭제 권한은 일반 적용에 필요하지 않습니다.

### 3. 다음 배포 단계로 전달할 값

- `public_subnet_ids`: 두 AZ의 ALB 배치 위치
- `application_subnet_ids`: 두 AZ의 private ECS 배치 위치
- `database_subnet_ids`: 인터넷 기본 경로 없는 RDS subnet group 위치
- `security_group_ids`: ALB, 앱, DB 접근 경계
- `server_repository_url` / `server_repository_arn`: 이미지 업로드와 IAM 정책

개발 환경 NAT는 첫 번째 AZ에 하나만 생성합니다. 해당 AZ 장애 시 다른 AZ의 앱 외부 통신도 영향을 받습니다. `nat_gateway_mode = "per_az"`로 바꾸면 각 AZ의 게이트웨이를 사용합니다. 비용과 목표 가용성을 정한 뒤 선택합니다. NAT는 ECR API/registry, 로그, 비밀값 서비스의 HTTPS 통신 경로도 제공합니다.

## 서버 연결 계약

서버 Dockerfile은 Java 21 다단계 빌드이며, 실행은 non-root 사용자입니다. 서버 이미지의 기본 프로필은 `prod`입니다.

| 설정 | 다음 ECS 단계에서 사용할 값 |
| --- | --- |
| 앱 포트 | `8080` |
| ALB health path | `/api/v1/health` |
| 관리 포트 | `8081`, 공개하지 않음 |
| Spring profile | `SPRING_PROFILES_ACTIVE=prod` |
| DB | `DB_URL`, `DB_USERNAME`, `DB_PASSWORD`를 외부에서 주입 |
| Flyway | 앱 계정과 별개로 마이그레이션 권한을 검토 |
| 이미지 식별 | 서버 커밋 SHA 태그 및 배포 digest |

RDS/PostGIS 초기화와 OSM 데이터 적재는 DB 생성과 별개입니다. 실제 그래프 적재 전 경로 검색은 `ROUTING_DATA_UNAVAILABLE`을 반환합니다. 건물 데이터 적재는 그늘 평가 단계에서 추가합니다.

## 파일 관리와 참고

IDE 설정, 실제 `terraform.tfvars`, `backend.hcl`, 상태 파일과 plan, 자격 증명은 Git에서 제외합니다. 예시에는 실제 비밀값을 넣지 않습니다. `.terraform.lock.hcl`은 커밋합니다.

- [Terraform S3 backend와 잠금](https://developer.hashicorp.com/terraform/language/backend/s3)
- [Terraform 플랫폼별 provider 체크섬](https://developer.hashicorp.com/terraform/cli/commands/providers/lock)
- [Terraform AWS 모의 테스트](https://developer.hashicorp.com/terraform/language/tests/mocking)
- [ECR와 private subnet 통신](https://docs.aws.amazon.com/AmazonECR/latest/userguide/vpc-endpoints.html)
- [GitHub Actions OIDC와 AWS](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws)

[기반 구현 검증 기록](docs/foundation-verification.md)

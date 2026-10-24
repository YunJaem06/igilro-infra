# ECS Fargate·ALB와 개발 서버 배포

Terraform은 AWS 기반·ALB·IAM·최초 서비스와 배포 템플릿을 관리합니다. 서버 저장소의 `deploy.yml`은 검증된 서버 이미지를 발행하고 private Fargate 작업으로 DB 초기화/Flyway를 수행한 뒤 서비스를 활성화·갱신합니다. 이 구현 과정에서 실제 AWS apply나 배포는 실행하지 않았습니다.

## 실행 구조와 소유권

- ALB는 public 서브넷 2개, ECS는 private application 서브넷 2개에 배치합니다. RDS는 기존 isolated database 서브넷을 사용합니다. 태스크 public IP와 ECS Exec는 꺼져 있습니다.
- ALB만 앱 8080에 접근합니다. ALB health는 `GET /api/v1/health`, HTTP 200입니다. 관리 포트 8081은 SG와 task port mapping에 공개하지 않습니다.
- 서버/마이그레이션은 Fargate Linux X86_64, 0.5 vCPU/1 GiB입니다. 초기화는 0.25 vCPU/512 MiB입니다. CI는 `linux/amd64` 이미지를 명시적으로 빌드합니다. 로컬 Mac ARM64 검증과 AWS 실행 아키텍처를 혼동하지 않습니다.
- 실행 역할은 이미지 pull·로그·해당 DB secret 주입만 수행합니다. 앱과 migration의 task role에는 AWS 권한을 부여하지 않습니다. bootstrap task role만 관리자 secret을 읽고 두 역할 secret을 초기화할 수 있습니다.
- GitHub의 일반 배포 역할은 관리자 secret을 읽거나 bootstrap 역할을 전달할 수 없습니다. `dev-bootstrap` 환경의 별도 역할만 초기화 task를 실행합니다. 비밀번호는 GitHub runner·Terraform·SSM 설정에 전달하지 않습니다.
- 로그는 `/ecs/igilro-dev/{application,migration,bootstrap}`에 14일 보관합니다. Container Insights도 켜져 있습니다.
- Terraform 최초 서비스는 실제 ECR digest가 지정된 후 `desired_count=0`으로 생성합니다. `task_definition`, `desired_count`는 이후 CI가 관리하도록 ignore_changes를 적용합니다. 첫 배포는 1개로 활성화하고, 다음 배포는 현재 실행 수를 보존합니다. 자동 확장은 후속 범위입니다.
- `initial_server_image_digest`는 최초 생성용입니다. 서비스 활성화 후 값을 null로 돌리거나 매 릴리스마다 변경하지 않습니다. Terraform apply와 배포 작업을 동시에 실행하지 않습니다. 환경/리소스 설정 변경 후 apply하고 다음 배포에서 새 task 템플릿을 반영합니다.

태스크는 secret JSON 키를 사용하므로 Fargate platform `1.4.0`을 고정합니다. 비밀번호가 회전하면 새 태스크를 시작해야 주입값이 갱신됩니다. [AWS secret 주입 문서](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/secrets-envvar-secrets-manager.html)를 참고합니다.

## 1. AWS 기반 생성

먼저 기존 README의 SSO·원격 backend 설정을 완료합니다. 아래는 macOS/zsh 예시입니다.

```sh
export AWS_PROFILE=igilro-dev
aws sts get-caller-identity
cp environments/dev/terraform.tfvars.example environments/dev/terraform.tfvars
cp environments/dev/backend.hcl.example environments/dev/backend.hcl
# 실제 계정·backend 값을 채운 후
terraform -chdir=environments/dev init -backend-config=backend.hcl
terraform -chdir=environments/dev plan -out=dev.tfplan
terraform -chdir=environments/dev apply dev.tfplan
terraform -chdir=environments/dev output
```

최초에는 `initial_server_image_digest=null`을 유지합니다. 클러스터·ALB·로그·IAM·ECR·SSM 템플릿이 만들어지고 ECS 서비스는 아직 만들지 않습니다. 존재하지 않는 이미지로 태스크를 시작하지 않기 위한 두 단계 구성입니다. 적용 역할에는 ECS/ELB의 service-linked role을 최초 생성할 권한도 필요합니다.

계정에 `token.actions.githubusercontent.com` OIDC provider가 이미 있다면 그 ARN을 `github_oidc_provider_arn`에 전달합니다. 계정 공용 provider를 중복 생성하거나 다른 Terraform state에 중복 등록하지 않습니다. [AWS service-linked role](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/using-service-linked-roles.html), [GitHub OIDC 설정](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws).

ALB·Fargate·로그·Advanced SSM parameter는 기존 NAT/RDS 등과 함께 AWS 사용 비용에 포함됩니다. 모의 테스트는 AWS 자원을 생성하지 않습니다.

## 2. HTTPS 또는 개발 HTTP 설정

기본값은 ALB HTTP listener의 고정 503 응답입니다. API 트래픽을 받으려면 다음 중 하나를 명시합니다.

- HTTPS: 서울 리전의 발급 완료된 ACM `certificate_arn`과 `api_domain_name`을 함께 지정합니다. Terraform의 `alb_dns_name` / `alb_zone_id`를 이용해 DNS alias를 생성합니다. HTTP 80은 HTTPS 443으로 리다이렉트합니다. 인증서 발급과 DNS zone 생성은 이 모듈에서 자동화하지 않습니다.
- 임시 개발 검증: `allow_development_http=true`를 지정하면 `http://<ALB DNS>`로 접근할 수 있습니다. 암호화되지 않는 개발용 주소이므로 실제 서비스에서는 HTTPS로 전환합니다. Flutter 릴리스의 평문 HTTP 허용 설정도 별도로 확인합니다.

`terraform output -raw api_url`은 설정한 주소를 반환합니다. 둘 다 설정하지 않으면 배포 스크립트가 서비스 활성화를 거부합니다. 서비스 활성화 전에 TLS/DNS 설정을 완료합니다.

## 3. GitHub 설정과 이미지 발행

두 저장소의 변경을 먼저 커밋·푸시하고 CI 성공을 확인합니다. 서버 저장소 Settings → Environments에 **dev**, **dev-bootstrap**을 생성합니다. 두 환경 모두 배포 가능 branch를 **main만** 허용합니다. bootstrap 환경에는 관리자 DB 초기화에 맞는 reviewer 보호도 설정할 수 있습니다. 환경을 쓰는 OIDC sub에는 branch가 포함되지 않으므로 환경 branch 제한이 필요합니다.

서버 저장소의 공통 Actions **Variables**에 다음 값을 입력합니다. 장기 AWS access key를 Secrets에 저장하지 않습니다.

| 공통 repository variable | 값 |
| --- | --- |
| `AWS_ACCOUNT_ID` | 실제 12자리 AWS 계정 |
| `AWS_REGION` | `ap-northeast-2` |
| `DEPLOYMENT_PARAMETER` | Terraform `deployment_parameter_name`, 기본 `/igilro-dev/deployment` |
| `INFRA_REF` | 이번 구현이 포함되고 CI를 통과한 infra의 **전체 40자리 커밋 SHA** |

`dev` environment variable `AWS_DEPLOY_ROLE_ARN`에는 Terraform `github_deploy_role_arn`을, `dev-bootstrap` environment variable `AWS_BOOTSTRAP_ROLE_ARN`에는 `github_bootstrap_role_arn`을 입력합니다. 공통 변수를 환경별로 서로 다르게 덮어쓰지 않습니다. INFRA_REF 변경은 배포 도구 변경이므로 해당 커밋을 검토합니다.

```sh
gh workflow run deploy.yml --repo YunJaem06/igilro-server --ref main -f operation=publish
```

또는 Actions → Deploy development server → Run workflow → main / publish를 선택합니다. 선택한 서버 커밋의 **Server CI push 실행이 성공**해야 진행합니다. Server CI 실행 중이면 완료 후 다시 실행합니다. deploy workflow는 main의 수동 실행만 지원하며 push만으로 실제 배포하지 않습니다.

서버는 서버 Git SHA, 초기화 이미지는 INFRA_REF로 태그를 붙입니다. 기존 태그가 있으면 이미지를 덮어쓰거나 재빌드하지 않고 digest를 재사용합니다. ECR은 IMMUTABLE입니다. 출력된 `server image: ...@sha256:...`의 digest를 다음 단계에 사용합니다. 초기화 이미지도 동일 작업에서 별도 ECR에 발행됩니다.

## 4. 정지된 최초 서비스 생성

`terraform.tfvars`에 publish 출력의 실제 `initial_server_image_digest="sha256:..."`를 기록하고 plan/apply합니다. listener/DNS 설정도 앞 단계에서 완료해야 합니다.

```sh
terraform -chdir=environments/dev plan -out=dev.tfplan
terraform -chdir=environments/dev apply dev.tfplan
```

이 시점에도 태스크 실행 수는 0입니다. 아직 secret 값이 없어도 서비스를 시작하지 않습니다. 같은 서버 커밋을 다음 단계에서 재선택하려면 그 커밋이 main head인 동안 진행합니다. 새 커밋으로 진행해도 publish가 새 이미지를 발행하므로 첫 서비스의 초기 digest가 실제 배포 digest와 같을 필요는 없습니다.

## 5. 초기화·마이그레이션·서비스 활성화

```sh
# 처음 한 번: 별도 bootstrap 역할로 PostGIS/계정을 만든 다음 일반 역할로 migration/deploy
gh workflow run deploy.yml --repo YunJaem06/igilro-server --ref main -f operation=initialize-and-deploy
# 이후 릴리스: DB 초기화 없이 migration/deploy
gh workflow run deploy.yml --repo YunJaem06/igilro-server --ref main -f operation=deploy
```

실행 순서는 이미지 발행/재사용 → 선택적 bootstrap exit 0 → Flyway exit 0 → 새 app revision 등록/갱신 → ECS rollout COMPLETED와 정확한 revision 확인 → 공개 `/api/v1/health` HTTP 200/`UP` 확인입니다. migration과 app은 **동일 서버 digest**를 사용합니다. Flyway는 웹 서버 없이 끝나는 일회성 작업이며 app에서는 꺼져 있습니다.

bootstrap과 migration은 AWS VPC 내부에서 실행됩니다. GitHub runner는 DB에 접속하지 않습니다. RunTask 실패 목록, 종료 코드 누락/비정상 종료, 제한 시간 초과는 실패 처리합니다. 시간 초과/중단 시 실행 중인 일회성 task 중지를 시도합니다. GitHub 강제 취소나 runner 종료 이후에는 ECS task 상태를 확인한 뒤 재시도합니다.

```sh
API_URL=$(terraform -chdir=environments/dev output -raw api_url)
curl --fail --show-error "$API_URL/api/v1/health"
```

OSM/건물 자료 적재는 별도 단계입니다. 빈 그래프에서 health가 UP이어도 경로 API는 `503 ROUTING_DATA_UNAVAILABLE`일 수 있습니다. 운영 프로필의 Swagger/OpenAPI는 기존대로 비활성화합니다.

## 실패와 복구

- migration 실패: 서비스를 갱신하지 않습니다. migration 로그와 Flyway history를 확인합니다. baseline/clean/DB rollback을 자동 실행하지 않습니다.
- rollout 실패: ECS circuit breaker와 스크립트의 복구가 이전 revision/실행 수 복원을 시도합니다. 첫 배포에 이전 정상 버전이 없으면 실행 수 0으로 복원합니다. ECS가 자동 롤백해 안정 상태가 되어도 요청한 revision이 아니면 CI는 실패합니다.
- 공개 health 실패: 이전 revision/실행 수로 복원하고 CI를 실패시킵니다. DB schema migration은 되돌리지 않으므로 릴리스는 이전 앱과 호환되는 expand/contract 방식으로 작성합니다.
- 복구 실패: ECS service events, 배포 revision, `/ecs/igilro-dev/*` 로그와 RDS 상태를 직접 확인합니다. 배포 실패를 성공으로 덮어쓰지 않습니다.
- Actions concurrency는 한 workflow를 중간 취소하지 않고 직렬화합니다. 콘솔/CLI/Terraform 등 다른 주체의 변경은 동시에 하지 않습니다.

[ECS circuit breaker](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/deployment-circuit-breaker.html), [ECS IAM action/resource 범위](https://docs.aws.amazon.com/service-authorization/latest/reference/list_ecs.html), [생성 시 태그 권한](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/supported-iam-actions-tagging.html).

실제 계정에서 IAM·리전 할당량·DNS/ACM·이미지 pull·ALB target health를 확인해야 최초 배포 검증이 끝납니다. 이 저장소의 AWS mock/SDK fake 테스트는 그 확인을 대체하지 않습니다. 자동 확장, 사용자 트래픽 알람/알림, WAF, 도메인/인증서 자동 발급과 데이터 적재 파이프라인은 후속 작업입니다.

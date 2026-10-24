# ECS/ALB·배포 파이프라인 검증 — 2026-10-24

macOS Apple Silicon, Terraform 1.17.0 / AWS provider 6.70.0, Python 3.12, Java 21 환경에서 검증했습니다. 실제 AWS API를 사용하는 plan/apply, ECR push, ECS task 실행, GitHub deploy 실행은 수행하지 않았습니다.

## 통과한 검사

- Terraform 7개 구성 fmt, init(-backend=false, -lockfile=readonly), validate 성공.
- AWS mock 테스트 **21개**: bootstrap 2, network 4, ecr 1, database 5, ecs 5, github-deployment 3, dev 1.
- Python 단위 테스트 **25개**: 기존 DB 도구 8, 새 배포 도구 17.
- 임시 TLS PostGIS/실제 서버 JAR 통합 테스트 **7개**: 초기화 반복, 기본 권한, 앱 읽기 전용, 과도한 역할·객체 소유 거부, 진짜 superuser가 아닌 관리자로 재실행, TLS CA 검증, migration 권한 없는 prod 앱 health.
- 두 저장소 workflow의 actionlint 1.7.12 검사 성공. optional shellcheck/pyflakes 실행은 제외했습니다.
- Terraform mock 실행이 실제 생성한 task JSON을 botocore RegisterTaskDefinition/RunTask 모델로 검증했습니다. 서로 다른 3개 상태의 app/migration/bootstrap 총 9개 task definition 요청이 형식 검사를 통과했습니다. AWS 요청은 보내지 않았습니다.

배포 테스트는 migration exit 1/종료 코드 누락/RunTask 실패 시 서비스 변경 차단, task timeout 시 중지, ECS eventual consistency, 자동 롤백 감지, 공개 health 실패 시 이전 서비스 복원, 실행 수 보존/최초 활성화, concurrent rollout 거부, image tag 재사용/AccessDenied 처리, AMD64 빌드 및 ECR 토큰 stdin 전달을 포함합니다.

새 배포 모듈의 태스크는 X86_64로 고정하고 workflow도 linux/amd64로 빌드합니다. 이번 변경에서 Dockerfile·서버 애플리케이션 소스·migration SQL은 바꾸지 않았습니다. 로컬 회귀 검증은 기존 ARM64 테스트 DB/JAR을 재사용했습니다. 실제 GitHub runner의 AMD64 빌드와 AWS 런타임 연결은 푸시/최초 적용 후 확인합니다.

통합 테스트는 기존 개발 DB와 분리한 임시 컨테이너를 사용하고 종료 시 정리했습니다. Secrets Manager는 fake를 사용했습니다. 실패·오류·건너뜀 없이 **총 53개 테스트**가 통과했습니다.

## 실제 계정에서 남은 확인

[최초 배포 절차](ecs-deployment.md)에 따라 원격 backend/계정, OIDC provider 재사용 여부, GitHub 환경 main 제한과 변수, 실제 RDS 가용성, ECR digest, private task 이미지 pull·secret 접근·로그, ALB target health와 DNS/ACM를 확인합니다. 최초 서비스 실행 수는 0이고 migration 성공 후 배포가 활성화합니다.

현재는 AWS 리소스를 생성하지 않았으므로 공개 배포 URL이나 실제 ALB health 성공 결과는 없습니다. CI/SDK fake/mock 검증과 실제 배포 성공을 구분합니다.

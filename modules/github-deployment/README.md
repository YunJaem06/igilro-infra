# GitHub OIDC deployment

`YunJaem06/igilro-server`의 정확한 environment sub와 STS audience를 신뢰합니다. `dev`는 이미지 발행/일반 배포, `dev-bootstrap`은 최초 관리자 작업을 실행합니다. GitHub environment branch 제한은 main으로 설정합니다.

일반 배포는 해당 ECR, SSM 설정, app/migration task family와 역할, 한 서비스만 대상으로 합니다. bootstrap 역할을 전달하거나 raw DB secret을 읽을 수 없습니다. bootstrap runner도 직접 DB secret을 읽지 않으며 bootstrap task만 실행할 수 있습니다.

계정에 GitHub OIDC provider가 이미 있으면 `existing_oidc_provider_arn`으로 재사용합니다. 모듈이 처음 생성한 provider를 여러 환경이 각각 중복 소유하지 않습니다. 추가 환경에서는 같은 provider ARN을 참조합니다.

[운영 설정](../../docs/ecs-deployment.md)에 GitHub 변수와 AWS 첫 적용 절차를 정리했습니다.

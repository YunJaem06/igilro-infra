# ECS runtime

Fargate cluster, public ALB/선택적 HTTPS, private app service, 역할별 로그와 IAM, 세 종류의 task template 및 non-secret SSM 배포 설정을 구성합니다.

실제 이미지 digest 없이 서비스/task definition을 만들지 않습니다. 이미지 발행 후 `initial_server_image_digest`로 실행 수 0인 서비스를 생성하고, CI가 초기화·migration 후 활성화합니다. 이후 서비스 revision/실행 수는 CI가 관리합니다. 태스크는 Linux X86_64, Fargate 1.4.0이며 서버 Docker build도 AMD64로 맞춥니다.

입력은 network/database/ecr 모듈 출력입니다. DB 비밀번호는 입력이나 출력에 포함하지 않습니다. [실제 적용과 소유권·복구 절차](../../docs/ecs-deployment.md)를 따릅니다.

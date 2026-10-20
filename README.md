# 이길로 인프라

이길로 서버의 AWS 인프라를 Terraform으로 관리하기 위한 저장소입니다.
서버 애플리케이션 코드는 별도 `igilro-server` 프로젝트에서 관리합니다.

## 현재 상태

저장소 기본 설정을 구성한 단계입니다. Terraform 코드와 배포 자동화는 이후 구현합니다.

## 예정된 구성

- 네트워크: VPC, 서브넷, 보안 그룹
- 애플리케이션: ECR 이미지 저장소, ALB, ECS/Fargate
- 데이터베이스: PostgreSQL 및 PostGIS 확장
- 도메인과 HTTPS: DNS 레코드, TLS 인증서
- 운영: 비밀값 관리, CloudWatch 로그와 알림
- 환경 분리: 개발 환경을 먼저 검증한 뒤 운영 환경으로 확장

## 구현 순서

1. 서버 프로젝트에 Java 21 컨테이너 이미지 빌드 설정을 추가합니다.
2. Terraform 상태 저장소와 개발 환경의 네트워크, 서버, DB를 구성합니다.
3. 도메인과 HTTPS를 연결합니다.
4. GitHub Actions를 통한 이미지 빌드와 배포를 연결합니다.
5. 경로 데이터를 적재하고 앱에서 실제 API 요청을 검증합니다.

## 파일 관리

- Terraform 코드, 문서, `.terraform.lock.hcl`은 Git으로 관리합니다.
- IDE 설정, Terraform 캐시와 상태 파일, 로컬 설정과 비밀값은 제외합니다.
- 설정 예시는 실제 비밀값 없이 `terraform.tfvars.example`처럼 작성합니다.

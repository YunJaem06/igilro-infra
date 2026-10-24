mock_provider "aws" {

  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:loadbalancer/app/igilro-test/1234567890123456" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:targetgroup/igilro-test/1234567890123456" }
  }
  mock_resource "aws_ecs_cluster" {
    defaults = { arn = "arn:aws:ecs:ap-northeast-2:123456789012:cluster/igilro-test" }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/igilro-test" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/igilro-test" }
  }
  mock_resource "aws_ecs_task_definition" {
    defaults = { arn = "arn:aws:ecs:ap-northeast-2:123456789012:task-definition/igilro-test:1" }
  }
}

variables {
  name_prefix                   = "igilro-test"
  aws_region                    = "ap-northeast-2"
  aws_account_id                = "123456789012"
  vpc_id                        = "vpc-11111111"
  public_subnet_ids             = ["subnet-11111111", "subnet-22222222"]
  application_subnet_ids        = ["subnet-33333333", "subnet-44444444"]
  alb_security_group_id         = "sg-11111111"
  application_security_group_id = "sg-22222222"
  repositories = {
    server    = { name = "igilro-test/server", arn = "arn:aws:ecr:ap-northeast-2:123456789012:repository/igilro-test/server", url = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/igilro-test/server" }
    bootstrap = { name = "igilro-test/bootstrap", arn = "arn:aws:ecr:ap-northeast-2:123456789012:repository/igilro-test/bootstrap", url = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/igilro-test/bootstrap" }
  }
  database_bootstrap = { host = "test.rds.amazonaws.com", secrets = { admin = "admin-arn" } }
  database_tasks = {
    application = {
      environment = { SPRING_FLYWAY_ENABLED = "false", DB_URL = "jdbc:postgresql://test/igilro?sslmode=verify-full" }
      secrets     = [{ name = "DB_PASSWORD", valueFrom = "application-arn:password::" }]
    }
    migration = {
      environment = { SPRING_FLYWAY_ENABLED = "true", SPRING_MAIN_WEB_APPLICATION_TYPE = "none" }
      secrets     = [{ name = "DB_PASSWORD", valueFrom = "migration-arn:password::" }]
    }
  }
  database_secret_policy_arns = { application = "arn:aws:iam::123456789012:policy/app", migration = "arn:aws:iam::123456789012:policy/migration", bootstrap = "arn:aws:iam::123456789012:policy/bootstrap" }
}

run "foundation_without_images_is_inert" {
  command = apply
  assert {
    condition = (
      length(aws_ecs_service.this) == 0 && length(aws_ecs_task_definition.initial) == 0 &&
      output.api_url == null && one(aws_lb_listener.http.default_action).type == "fixed-response" &&
      aws_lb_target_group.server.target_type == "ip" &&
      one(aws_lb_target_group.server.health_check).path == "/api/v1/health" &&
      aws_lb.this.enable_deletion_protection
    )
    error_message = "First apply must create no fake/running task or implicit public HTTP API."
  }
  assert {
    condition = (
      output.deployment_config.tasks.application.containerDefinitions[0].portMappings[0].containerPort == 8080 &&
      !can(output.deployment_config.tasks.migration.containerDefinitions[0].portMappings) &&
      output.deployment_config.network.awsvpcConfiguration.assignPublicIp == "DISABLED" &&
      output.deployment_config.tasks.application.runtimePlatform.cpuArchitecture == "X86_64" &&
      output.deployment_config.tasks.application.containerDefinitions[0].user == "10001:10001" &&
      length(output.deployment_config.tasks.bootstrap.containerDefinitions[0].secrets) == 0 &&
      aws_iam_role_policy_attachment.bootstrap_database.role == aws_iam_role.task["bootstrap"].name &&
      length(aws_iam_role_policy_attachment.database_read) == 2
    )
    error_message = "Only app 8080 is mapped, private AMD64 tasks use non-root and DB roles stay separated."
  }
}

run "real_image_creates_idle_private_service" {
  command = apply
  variables {
    initial_server_image_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    allow_development_http      = true
  }
  assert {
    condition = (
      aws_ecs_service.this[0].desired_count == 0 && aws_ecs_service.this[0].platform_version == "1.4.0" &&
      !one(aws_ecs_service.this[0].network_configuration).assign_public_ip &&
      one(aws_ecs_service.this[0].deployment_circuit_breaker).rollback &&
      one(aws_ecs_service.this[0].load_balancer).container_port == 8080 &&
      endswith(jsondecode(aws_ecs_task_definition.initial[0].container_definitions)[0].image, var.initial_server_image_digest) &&
      one(aws_lb_listener.http.default_action).type == "forward" &&
      output.deployment_config.service_created
    )
    error_message = "Service remains idle until bootstrap/migration succeed; use private Fargate with rollback and a real pinned image."
  }
}

run "https_redirects_http" {
  command = apply
  variables {
    certificate_arn = "arn:aws:acm:ap-northeast-2:123456789012:certificate/test"
    api_domain_name = "api.example.com"
  }
  assert {
    condition = (
      output.api_url == "https://api.example.com" && aws_lb_listener.https[0].protocol == "HTTPS" &&
      one(aws_lb_listener.http.default_action).type == "redirect" &&
      one(one(aws_lb_listener.http.default_action).redirect).protocol == "HTTPS"
    )
    error_message = "HTTPS must use the requested API domain and redirect HTTP."
  }
}

run "reject_unpinned_image" {
  command = plan
  variables { initial_server_image_digest = "latest" }
  expect_failures = [var.initial_server_image_digest]
}

run "reject_certificate_without_domain" {
  command = plan
  variables { certificate_arn = "arn:aws:acm:ap-northeast-2:123456789012:certificate/test" }
  expect_failures = [aws_lb.this]
}

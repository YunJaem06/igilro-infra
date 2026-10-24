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

  mock_resource "aws_db_instance" {
    defaults = {
      master_user_secret = [{
        secret_arn    = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:rds-master-test"
        kms_key_id    = "test-key"
        secret_status = "active"
      }]
    }
  }
}

variables {
  aws_account_id = "123456789012"
}

run "development_foundation_wiring" {
  command = apply

  assert {
    condition = (
      output.server_repository_name == "igilro-dev/server" &&
      length(output.public_subnet_ids) == 2 &&
      length(output.application_subnet_ids) == 2 &&
      length(output.database_subnet_ids) == 2 &&
      length(output.nat_gateway_ids) == 1 &&
      length(distinct(values(output.security_group_ids))) == 3
    )
    error_message = "The dev environment must connect isolated network tiers and its own immutable image repository."
  }
  assert {
    condition = (
      output.database_bootstrap.database == "igilro" &&
      output.database_bootstrap.region == "ap-northeast-2" &&
      length(output.database_secret_policy_arns) == 3 &&
      output.database_server_tasks.application.environment.SPRING_FLYWAY_ENABLED == "false"
    )
    error_message = "Dev database outputs must connect the private DB, separate secrets and migration settings."
  }
  assert {
    condition = (
      module.ecs.deployment_config.service_created == false &&
      module.ecs.deployment_config.tasks.application.containerDefinitions[0].name == "server" &&
      module.ecs.deployment_config.tasks.migration.containerDefinitions[0].name == "migration" &&
      module.ecs.deployment_config.tasks.bootstrap.containerDefinitions[0].name == "bootstrap" &&
      length(jsonencode(module.ecs.deployment_config)) <= 8192 &&
      output.api_url == null && output.deployment_parameter_name == "/igilro-dev/deployment"
    )
    error_message = "Runtime must wire all three task templates into a bounded non-secret SSM configuration without activating the API."
  }
}

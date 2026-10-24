mock_provider "aws" {
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
}

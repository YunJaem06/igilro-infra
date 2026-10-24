mock_provider "aws" {
  mock_resource "aws_db_instance" {
    defaults = {
      address = "database.test.ap-northeast-2.rds.amazonaws.com"
      master_user_secret = [{
        secret_arn    = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:rds-master-test"
        kms_key_id    = "test-key"
        secret_status = "active"
      }]
    }
  }
}

variables {
  name_prefix       = "igilro-test"
  aws_region        = "ap-northeast-2"
  subnet_ids        = ["subnet-11111111", "subnet-22222222"]
  security_group_id = "sg-12345678"
}

run "private_encrypted_database_with_managed_password" {
  command = apply
  assert {
    condition = (
      !aws_db_instance.this.publicly_accessible && aws_db_instance.this.storage_encrypted &&
      aws_db_instance.this.manage_master_user_password && aws_db_instance.this.password == null &&
      aws_db_instance.this.backup_retention_period == 7 && aws_db_instance.this.deletion_protection &&
      !aws_db_instance.this.skip_final_snapshot && !aws_db_instance.this.multi_az &&
      aws_db_instance.this.vpc_security_group_ids == toset([var.security_group_id]) &&
      one(aws_db_parameter_group.this.parameter).name == "rds.force_ssl" &&
      one(aws_db_parameter_group.this.parameter).value == "1"
    )
    error_message = "Database must be private, encrypted, TLS-only, protected, backed up and use an RDS-managed password."
  }
  assert {
    condition = (
      aws_secretsmanager_secret.migration.recovery_window_in_days == 7 &&
      aws_secretsmanager_secret.application.recovery_window_in_days == 7 &&
      jsondecode(aws_iam_policy.bootstrap_secrets.policy).Statement[1].Resource ==
      [aws_secretsmanager_secret.migration.arn, aws_secretsmanager_secret.application.arn] &&
      jsondecode(aws_iam_policy.role_secret_read["application"].policy).Statement[0].Resource == [aws_secretsmanager_secret.application.arn] &&
      jsondecode(aws_iam_policy.role_secret_read["migration"].policy).Statement[0].Resource == [aws_secretsmanager_secret.migration.arn]
    )
    error_message = "Bootstrap may write only role secrets; app and migration tasks must read separate credentials."
  }
  assert {
    condition = (
      output.server_task_configuration.application.environment.SPRING_FLYWAY_ENABLED == "false" &&
      output.server_task_configuration.migration.environment.SPRING_FLYWAY_ENABLED == "true" &&
      output.server_task_configuration.migration.environment.SPRING_MAIN_WEB_APPLICATION_TYPE == "none" &&
      strcontains(output.server_task_configuration.application.environment.DB_URL, "sslmode=verify-full") &&
      output.server_task_configuration.application.secrets[1].valueFrom == "${aws_secretsmanager_secret.application.arn}:password::"
    )
    error_message = "Application must disable Flyway and migration must run non-web, with TLS and secret ARN selectors."
  }
}

run "reject_unsupported_postgres_major" {
  command = plan
  variables { engine_version = "18" }
  expect_failures = [var.engine_version]
}

run "reject_single_subnet" {
  command = plan
  variables { subnet_ids = ["subnet-11111111"] }
  expect_failures = [var.subnet_ids]
}

run "reject_disabled_backups" {
  command = plan
  variables { backup_retention_period = 0 }
  expect_failures = [var.backup_retention_period]
}

run "reject_invalid_storage_ceiling" {
  command = plan
  variables { max_allocated_storage = 20 }
  expect_failures = [var.max_allocated_storage]
}

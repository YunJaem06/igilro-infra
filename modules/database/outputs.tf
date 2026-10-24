output "instance_identifier" {
  value       = aws_db_instance.this.identifier
  description = "RDS identifier used by readiness and engine-version checks."
}

output "address" {
  value       = aws_db_instance.this.address
  description = "Private RDS DNS endpoint; preserve this hostname for TLS verification."
}

output "bootstrap_config" {
  description = "Non-secret JSON input for scripts/bootstrap_database.py. Contains identifiers and ARNs only."
  value = {
    region               = var.aws_region
    host                 = aws_db_instance.this.address
    port                 = aws_db_instance.this.port
    database             = var.database_name
    admin_username       = local.admin_username
    migration_username   = local.migration_username
    application_username = local.app_username
    secrets = {
      admin       = aws_db_instance.this.master_user_secret[0].secret_arn
      migration   = aws_secretsmanager_secret.migration.arn
      application = aws_secretsmanager_secret.application.arn
    }
  }
}

output "secret_policy_arns" {
  value = {
    bootstrap   = aws_iam_policy.bootstrap_secrets.arn
    application = aws_iam_policy.role_secret_read["application"].arn
    migration   = aws_iam_policy.role_secret_read["migration"].arn
  }
  description = "Attach bootstrap to the bootstrap task role; application/migration to their separate ECS execution roles."
}

output "server_task_configuration" {
  description = "Environment and Secrets Manager JSON-key bindings for later ECS tasks. No password values."
  value = {
    application = {
      environment = {
        SPRING_PROFILES_ACTIVE = "prod"
        SPRING_FLYWAY_ENABLED  = "false"
        DB_URL                 = "jdbc:postgresql://${aws_db_instance.this.address}:5432/${var.database_name}?sslmode=verify-full&sslrootcert=/app/certs/rds-ca.pem&connectTimeout=5"
      }
      secrets = [
        { name = "DB_USERNAME", valueFrom = "${aws_secretsmanager_secret.application.arn}:username::" },
        { name = "DB_PASSWORD", valueFrom = "${aws_secretsmanager_secret.application.arn}:password::" }
      ]
    }
    migration = {
      environment = {
        SPRING_PROFILES_ACTIVE           = "prod"
        SPRING_MAIN_WEB_APPLICATION_TYPE = "none"
        SPRING_FLYWAY_ENABLED            = "true"
        DB_URL                           = "jdbc:postgresql://${aws_db_instance.this.address}:5432/${var.database_name}?sslmode=verify-full&sslrootcert=/app/certs/rds-ca.pem&connectTimeout=5"
      }
      secrets = [
        { name = "DB_USERNAME", valueFrom = "${aws_secretsmanager_secret.migration.arn}:username::" },
        { name = "DB_PASSWORD", valueFrom = "${aws_secretsmanager_secret.migration.arn}:password::" }
      ]
    }
  }
}

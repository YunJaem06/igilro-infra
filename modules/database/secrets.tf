# Metadata only. Secret values are initialized by the private-network bootstrap tool,
# so passwords are never supplied to Terraform resources, data sources, or outputs.
resource "aws_secretsmanager_secret" "migration" {
  name                    = "${var.name_prefix}/database/migration"
  description             = "DDL/data-import account; populated by database bootstrap"
  recovery_window_in_days = 7
  tags                    = var.tags
}

resource "aws_secretsmanager_secret" "application" {
  name                    = "${var.name_prefix}/database/application"
  description             = "Read-only route API account; populated by database bootstrap"
  recovery_window_in_days = 7
  tags                    = var.tags
}

resource "aws_iam_policy" "bootstrap_secrets" {
  name        = "${var.name_prefix}-database-bootstrap-secrets"
  description = "Bootstrap task may read DB credentials and initialize only the two role secrets"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          aws_db_instance.this.master_user_secret[0].secret_arn,
          aws_secretsmanager_secret.migration.arn,
          aws_secretsmanager_secret.application.arn
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:PutSecretValue"]
        Resource = [aws_secretsmanager_secret.migration.arn, aws_secretsmanager_secret.application.arn]
      }
    ]
  })
  tags = var.tags
}

resource "aws_iam_policy" "role_secret_read" {
  for_each = {
    application = aws_secretsmanager_secret.application.arn
    migration   = aws_secretsmanager_secret.migration.arn
  }
  name        = "${var.name_prefix}-database-${each.key}-secret-read"
  description = "ECS execution role reads only the ${each.key} database secret"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [each.value]
    }]
  })
  tags = var.tags
}

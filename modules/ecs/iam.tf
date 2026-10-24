locals {
  task_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = var.aws_account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:ecs:${var.aws_region}:${var.aws_account_id}:*" }
      }
    }]
  })
}

resource "aws_iam_role" "execution" {
  for_each           = local.roles
  name               = "${var.name_prefix}-${each.key}-execution"
  assume_role_policy = local.task_trust
  tags               = var.tags
}

resource "aws_iam_role" "task" {
  for_each           = local.roles
  name               = "${var.name_prefix}-${each.key}-task"
  assume_role_policy = local.task_trust
  tags               = var.tags
}

resource "aws_iam_role_policy" "execution" {
  for_each = local.roles
  name     = "image-and-logs"
  role     = aws_iam_role.execution[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
      {
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]
        Resource = var.repositories[each.key == "bootstrap" ? "bootstrap" : "server"].arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.tasks[each.key].arn}:*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "database_read" {
  for_each   = toset(["application", "migration"])
  role       = aws_iam_role.execution[each.key].name
  policy_arn = var.database_secret_policy_arns[each.key]
}

resource "aws_iam_role_policy_attachment" "bootstrap_database" {
  role       = aws_iam_role.task["bootstrap"].name
  policy_arn = var.database_secret_policy_arns.bootstrap
}

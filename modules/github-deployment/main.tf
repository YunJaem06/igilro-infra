resource "aws_iam_openid_connect_provider" "github" {
  count          = var.existing_oidc_provider_arn == null ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  tags           = var.tags
}

locals {
  provider_arn = var.existing_oidc_provider_arn != null ? var.existing_oidc_provider_arn : aws_iam_openid_connect_provider.github[0].arn
  roles = {
    deploy    = ["application", "migration"]
    bootstrap = ["bootstrap"]
  }
  task_resource = "arn:aws:ecs:${var.aws_region}:${var.aws_account_id}:task/${split("/", var.cluster_arn)[1]}/*"
}

resource "aws_iam_role" "github" {
  for_each             = local.roles
  name                 = "${var.name_prefix}-github-${each.key}"
  max_session_duration = 3600
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = local.provider_arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${var.repository}:environment:${var.environment_name}${each.key == "bootstrap" ? "-bootstrap" : ""}"
        }
      }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "tasks" {
  for_each = local.roles
  name     = "deploy-tasks"
  role     = aws_iam_role.github[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ssm:GetParameter"], Resource = var.deployment_parameter_arn },
      {
        Effect   = "Allow", Action = ["ecs:RegisterTaskDefinition"]
        Resource = [for role in each.value : var.task_family_arns[role]]
      },
      {
        Effect    = "Allow", Action = ["ecs:TagResource"]
        Resource  = [for role in each.value : var.task_family_arns[role]]
        Condition = { StringEquals = { "ecs:CreateAction" = "RegisterTaskDefinition" } }
      },
      {
        Effect    = "Allow", Action = ["iam:PassRole"]
        Resource  = flatten([for role in each.value : [var.execution_role_arns[role], var.task_role_arns[role]]])
        Condition = { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } }
      },
      {
        Effect    = "Allow", Action = ["ecs:RunTask"]
        Resource  = [var.task_family_arns[each.key == "bootstrap" ? "bootstrap" : "migration"]]
        Condition = { ArnEquals = { "ecs:cluster" = var.cluster_arn } }
      },
      {
        Effect    = "Allow", Action = ["ecs:DescribeTasks", "ecs:StopTask"], Resource = local.task_resource
        Condition = { ArnEquals = { "ecs:cluster" = var.cluster_arn } }
      },
      { Effect = "Allow", Action = ["ecr:DescribeImages"], Resource = var.repository_arns }
    ]
  })
}

resource "aws_iam_role_policy" "deploy" {
  name = "publish-and-service"
  role = aws_iam_role.github["deploy"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
      {
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage"]
        Resource = var.repository_arns
      },
      { Effect = "Allow", Action = ["ecs:DescribeServices", "ecs:UpdateService"], Resource = var.service_arn }
    ]
  })
}

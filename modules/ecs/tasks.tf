locals {
  containers = {
    for role in local.roles : role => merge({
      name        = role == "application" ? "server" : role
      essential   = true
      user        = "10001:10001"
      stopTimeout = 60
      environment = role == "bootstrap" ? [
        { name = "DATABASE_BOOTSTRAP_CONFIG", value = jsonencode(var.database_bootstrap) }
      ] : [for name, value in var.database_tasks[role].environment : { name = name, value = value }]
      secrets = role == "bootstrap" ? [] : var.database_tasks[role].secrets
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.tasks[role].name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = role
        }
      }
      }, role == "application" ? {
      portMappings = [{ containerPort = 8080, protocol = "tcp" }]
      } : {}, role == "bootstrap" ? {
      command = ["--config-env", "DATABASE_BOOTSTRAP_CONFIG", "--ssl-root-cert", "/app/certs/rds-ca.pem"]
    } : {})
  }
  task_templates = {
    for role in local.roles : role => {
      family                  = local.families[role]
      networkMode             = "awsvpc"
      requiresCompatibilities = ["FARGATE"]
      cpu                     = role == "bootstrap" ? "256" : "512"
      memory                  = role == "bootstrap" ? "512" : "1024"
      executionRoleArn        = aws_iam_role.execution[role].arn
      taskRoleArn             = aws_iam_role.task[role].arn
      runtimePlatform         = { cpuArchitecture = "X86_64", operatingSystemFamily = "LINUX" }
      containerDefinitions    = [local.containers[role]]
      tags                    = [for key, value in var.tags : { key = key, value = value }]
    }
  }
  deployment_config = {
    version         = 1
    region          = var.aws_region
    account_id      = var.aws_account_id
    cluster         = aws_ecs_cluster.this.arn
    service         = local.service_name
    service_created = var.initial_server_image_digest != null
    target_group    = aws_lb_target_group.server.arn
    api_url         = local.api_url
    repositories    = var.repositories
    tasks           = local.task_templates
    network = {
      awsvpcConfiguration = {
        subnets        = var.application_subnet_ids
        securityGroups = [var.application_security_group_id]
        assignPublicIp = "DISABLED"
      }
    }
  }
}

# Identifiers and templates only. Passwords remain in Secrets Manager.
resource "aws_ssm_parameter" "deployment" {
  name  = "/${var.name_prefix}/deployment"
  type  = "String"
  tier  = "Advanced"
  value = jsonencode(local.deployment_config)
  tags  = var.tags
  lifecycle {
    precondition {
      condition     = length(jsonencode(local.deployment_config)) <= 8192
      error_message = "Deployment configuration exceeds the Advanced SSM parameter size limit."
    }
  }
}

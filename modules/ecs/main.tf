locals {
  roles        = toset(["application", "migration", "bootstrap"])
  service_name = "${var.name_prefix}-server"
  families = {
    application = "${var.name_prefix}-server"
    migration   = "${var.name_prefix}-migration"
    bootstrap   = "${var.name_prefix}-bootstrap"
  }
  api_url = var.certificate_arn != null ? "https://${var.api_domain_name}" : (var.allow_development_http ? "http://${aws_lb.this.dns_name}" : null)
}

resource "aws_ecs_cluster" "this" {
  name = var.name_prefix
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
  tags = var.tags
}

resource "aws_cloudwatch_log_group" "tasks" {
  for_each          = local.roles
  name              = "/ecs/${var.name_prefix}/${each.key}"
  retention_in_days = 14
  tags              = var.tags
}

resource "aws_lb" "this" {
  name                       = "${var.name_prefix}-api"
  internal                   = false
  load_balancer_type         = "application"
  subnets                    = var.public_subnet_ids
  security_groups            = [var.alb_security_group_id]
  drop_invalid_header_fields = true
  enable_deletion_protection = var.alb_deletion_protection
  idle_timeout               = 60
  tags                       = var.tags
  lifecycle {
    precondition {
      condition     = (var.certificate_arn == null) == (var.api_domain_name == null)
      error_message = "Set both certificate_arn and api_domain_name for HTTPS."
    }
  }
}

resource "aws_lb_target_group" "server" {
  name                 = "${var.name_prefix}-server"
  port                 = 8080
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30
  health_check {
    path                = "/api/v1/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
  tags = var.tags
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = var.certificate_arn != null ? "redirect" : (var.allow_development_http ? "forward" : "fixed-response")
    target_group_arn = var.certificate_arn == null && var.allow_development_http ? aws_lb_target_group.server.arn : null
    dynamic "redirect" {
      for_each = var.certificate_arn != null ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
    dynamic "fixed_response" {
      for_each = var.certificate_arn == null && !var.allow_development_http ? [1] : []
      content {
        content_type = "text/plain"
        message_body = "HTTPS is not configured"
        status_code  = "503"
      }
    }
  }
  tags = var.tags
}

resource "aws_lb_listener" "https" {
  count             = var.certificate_arn != null ? 1 : 0
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = var.certificate_arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.server.arn
  }
  tags = var.tags
}

# Terraform establishes an inert first service only after a real image exists.
# CI owns subsequent revisions and the active desired count; no fake bootstrap image.
resource "aws_ecs_task_definition" "initial" {
  count                    = var.initial_server_image_digest != null ? 1 : 0
  family                   = local.families.application
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.execution["application"].arn
  task_role_arn            = aws_iam_role.task["application"].arn
  runtime_platform {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }
  container_definitions = jsonencode([merge(local.containers.application, {
    image = "${var.repositories.server.url}@${var.initial_server_image_digest}"
  })])
  tags = var.tags
}

resource "aws_ecs_service" "this" {
  count                              = var.initial_server_image_digest != null ? 1 : 0
  name                               = local.service_name
  cluster                            = aws_ecs_cluster.this.id
  task_definition                    = aws_ecs_task_definition.initial[0].arn
  desired_count                      = 0
  launch_type                        = "FARGATE"
  platform_version                   = "1.4.0"
  health_check_grace_period_seconds  = 120
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  enable_execute_command             = false
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  network_configuration {
    subnets          = var.application_subnet_ids
    security_groups  = [var.application_security_group_id]
    assign_public_ip = false
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.server.arn
    container_name   = "server"
    container_port   = 8080
  }
  tags       = var.tags
  depends_on = [aws_lb_listener.http, aws_lb_listener.https]
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }
}

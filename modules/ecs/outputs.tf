output "cluster_arn" { value = aws_ecs_cluster.this.arn }
output "service_arn" {
  value = "arn:aws:ecs:${var.aws_region}:${var.aws_account_id}:service/${aws_ecs_cluster.this.name}/${local.service_name}"
}
output "task_family_arns" {
  value = { for role, family in local.families : role => "arn:aws:ecs:${var.aws_region}:${var.aws_account_id}:task-definition/${family}:*" }
}
output "execution_role_arns" { value = { for role, item in aws_iam_role.execution : role => item.arn } }
output "task_role_arns" { value = { for role, item in aws_iam_role.task : role => item.arn } }
output "deployment_parameter_arn" { value = aws_ssm_parameter.deployment.arn }
output "deployment_parameter_name" { value = aws_ssm_parameter.deployment.name }
output "alb_dns_name" { value = aws_lb.this.dns_name }
output "alb_zone_id" { value = aws_lb.this.zone_id }
output "api_url" { value = local.api_url }
output "deployment_config" {
  description = "Non-secret configuration for local inspection and mocked tests; pipeline reads its SSM copy."
  value       = local.deployment_config
}

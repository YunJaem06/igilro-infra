output "vpc_id" {
  description = "VPC for the ALB, ECS and RDS resources."
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "ALB/NAT subnets across all configured AZs."
  value       = module.network.public_subnet_ids
}

output "application_subnet_ids" {
  description = "Private ECS subnets across all configured AZs."
  value       = module.network.application_subnet_ids
}

output "database_subnet_ids" {
  description = "Isolated subnets for the RDS subnet group."
  value       = module.network.database_subnet_ids
}

output "security_group_ids" {
  description = "Security groups for ALB, application and PostgreSQL."
  value       = module.network.security_group_ids
}

output "nat_gateway_ids" {
  description = "NAT gateways keyed by AZ."
  value       = module.network.nat_gateway_ids
}

output "server_repository_name" {
  description = "Server ECR repository name."
  value       = module.server_images.repository_name
}

output "server_repository_arn" {
  description = "Repository ARN used by deployment IAM policies."
  value       = module.server_images.repository_arn
}

output "server_repository_url" {
  description = "Server image push URL; use a Git commit SHA as the tag."
  value       = module.server_images.repository_url
}

output "database_instance_identifier" {
  description = "Private PostgreSQL instance identifier."
  value       = module.database.instance_identifier
}

output "database_bootstrap" {
  description = "Non-secret initialization input: terraform output -json database_bootstrap."
  value       = module.database.bootstrap_config
}

output "database_secret_policy_arns" {
  description = "Policies for bootstrap task role and separate server/migration execution roles."
  value       = module.database.secret_policy_arns
}

output "database_server_tasks" {
  description = "DB environment variables and secret ARN selectors for the application and one-off Flyway tasks."
  value       = module.database.server_task_configuration
}

output "api_url" { value = module.ecs.api_url }
output "alb_dns_name" { value = module.ecs.alb_dns_name }
output "alb_zone_id" { value = module.ecs.alb_zone_id }
output "deployment_parameter_name" { value = module.ecs.deployment_parameter_name }
output "github_deploy_role_arn" { value = module.github_deployment.deploy_role_arn }
output "github_bootstrap_role_arn" { value = module.github_deployment.bootstrap_role_arn }
output "bootstrap_repository_url" { value = module.bootstrap_images.repository_url }

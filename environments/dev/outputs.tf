output "vpc_id" {
  description = "VPC for the future ALB, ECS and RDS resources."
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
  description = "Isolated subnets for the future RDS subnet group."
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
  description = "Repository ARN for future deployment IAM policies."
  value       = module.server_images.repository_arn
}

output "server_repository_url" {
  description = "Server image push URL; use a Git commit SHA as the tag."
  value       = module.server_images.repository_url
}

output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Public ALB/NAT subnet IDs in availability_zones order."
  value       = [for az in var.availability_zones : aws_subnet.public[az].id]
}

output "application_subnet_ids" {
  description = "Private ECS subnet IDs in availability_zones order."
  value       = [for az in var.availability_zones : aws_subnet.application[az].id]
}

output "database_subnet_ids" {
  description = "Isolated RDS subnet IDs in availability_zones order."
  value       = [for az in var.availability_zones : aws_subnet.database[az].id]
}

output "security_group_ids" {
  description = "Explicit ALB, application and PostgreSQL security groups."
  value = {
    alb         = aws_security_group.alb.id
    application = aws_security_group.application.id
    database    = aws_security_group.database.id
  }
}

output "nat_gateway_ids" {
  description = "Zonal NAT gateway IDs, keyed by the AZ hosting each gateway."
  value       = { for az, gateway in aws_nat_gateway.this : az => gateway.id }
}

output "repository_name" {
  description = "Repository name."
  value       = aws_ecr_repository.this.name
}

output "repository_arn" {
  description = "Repository ARN for later deployment IAM policies."
  value       = aws_ecr_repository.this.arn
}

output "repository_url" {
  description = "Image push URL; append an immutable Git commit SHA tag."
  value       = aws_ecr_repository.this.repository_url
}

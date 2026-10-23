output "state_bucket_name" {
  description = "Copy this name into each environment's backend.hcl."
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "Bucket ARN for later least-privilege state access policies."
  value       = aws_s3_bucket.state.arn
}

output "state_region" {
  description = "Region to use in backend.hcl."
  value       = var.aws_region
}

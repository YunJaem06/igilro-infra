variable "name_prefix" { type = string }
variable "aws_region" { type = string }
variable "aws_account_id" { type = string }
variable "vpc_id" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "application_subnet_ids" { type = list(string) }
variable "alb_security_group_id" { type = string }
variable "application_security_group_id" { type = string }
variable "repositories" {
  type = map(object({ arn = string, url = string, name = string }))
}
variable "database_bootstrap" { type = any }
variable "database_tasks" { type = any }
variable "database_secret_policy_arns" { type = map(string) }
variable "initial_server_image_digest" {
  description = "After publish, pin the first server sha256 digest. Null creates runtime foundations without a service."
  type        = string
  default     = null
  validation {
    condition     = var.initial_server_image_digest == null ? true : can(regex("^sha256:[0-9a-f]{64}$", var.initial_server_image_digest))
    error_message = "Use a full sha256 image digest, never a mutable tag."
  }
}
variable "certificate_arn" {
  description = "Issued ACM certificate in this ALB's region."
  type        = string
  default     = null
}
variable "api_domain_name" {
  description = "DNS name covered by the certificate; create its ALB alias separately."
  type        = string
  default     = null
  validation {
    condition     = var.api_domain_name == null ? true : can(regex("^[a-z0-9][a-z0-9.-]+[a-z0-9]$", var.api_domain_name))
    error_message = "Use a plain lowercase DNS hostname without a scheme or path."
  }
}
variable "allow_development_http" {
  description = "Explicitly allow unencrypted HTTP only for development without a domain/certificate."
  type        = bool
  default     = false
}
variable "alb_deletion_protection" {
  type    = bool
  default = true
}
variable "tags" {
  type    = map(string)
  default = {}
}

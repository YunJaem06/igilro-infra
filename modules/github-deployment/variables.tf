variable "name_prefix" { type = string }
variable "aws_account_id" { type = string }
variable "aws_region" { type = string }
variable "repository" {
  type    = string
  default = "YunJaem06/igilro-server"
  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.repository))
    error_message = "Use an exact owner/repository, without wildcards."
  }
}
variable "environment_name" {
  type    = string
  default = "dev"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]+$", var.environment_name))
    error_message = "Use a plain environment name without wildcards or colons."
  }
}
variable "existing_oidc_provider_arn" {
  description = "Reuse the account's existing GitHub provider. Null creates it once; import/reuse if already present."
  type        = string
  default     = null
}
variable "repository_arns" { type = list(string) }
variable "cluster_arn" { type = string }
variable "service_arn" { type = string }
variable "task_family_arns" { type = map(string) }
variable "execution_role_arns" { type = map(string) }
variable "task_role_arns" { type = map(string) }
variable "deployment_parameter_arn" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}

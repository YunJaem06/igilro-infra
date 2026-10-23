variable "aws_account_id" {
  description = "Expected AWS account ID. Prevents accidentally applying to another account."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must contain exactly 12 digits."
  }
}

variable "aws_region" {
  description = "Region for the shared Terraform state bucket."
  type        = string
  default     = "ap-northeast-2"
}

variable "project_name" {
  description = "Lowercase project name used for globally unique state bucket naming."
  type        = string
  default     = "igilro"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,18}[a-z0-9]$", var.project_name))
    error_message = "Use 3-20 lowercase letters, digits or hyphens, starting with a letter and ending with a letter or digit."
  }
}

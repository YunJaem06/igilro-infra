variable "aws_account_id" {
  description = "Expected AWS account ID. Must match the authenticated AWS CLI profile."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must contain exactly 12 digits."
  }
}

variable "aws_region" {
  description = "Region for the development environment."
  type        = string
  default     = "ap-northeast-2"
}

variable "project_name" {
  description = "Lowercase project prefix."
  type        = string
  default     = "igilro"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,18}[a-z0-9]$", var.project_name))
    error_message = "Use 3-20 lowercase letters, digits or hyphens, starting with a letter and ending with a letter or digit."
  }
}

variable "vpc_cidr" {
  description = "Development VPC CIDR. Must not overlap networks it will later connect to."
  type        = string
  default     = "10.42.0.0/16"
}

variable "availability_zones" {
  description = "Two or three AZs in aws_region; preserve their order after the first apply."
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
}

variable "nat_gateway_mode" {
  description = "single for shared development egress; per_az for separate egress in each AZ."
  type        = string
  default     = "single"
}

variable "name_prefix" {
  description = "Resource name prefix, including the project and environment."
  type        = string
}

variable "aws_region" {
  description = "AWS region used for the S3 gateway endpoint."
  type        = string
}

variable "vpc_cidr" {
  description = "Canonical IPv4 VPC CIDR, with a prefix between /16 and /19."
  type        = string

  validation {
    condition = try(
      can(cidrnetmask(var.vpc_cidr)) &&
      tonumber(split("/", var.vpc_cidr)[1]) >= 16 &&
      tonumber(split("/", var.vpc_cidr)[1]) <= 19 &&
      "${cidrhost(var.vpc_cidr, 0)}/${split("/", var.vpc_cidr)[1]}" == var.vpc_cidr,
      false
    )
    error_message = "Use a canonical IPv4 CIDR between /16 and /19, such as 10.42.0.0/16."
  }
}

variable "availability_zones" {
  description = "Two or three distinct AZs in aws_region. Keep their order stable to preserve subnet CIDRs."
  type        = list(string)

  validation {
    condition = (
      length(var.availability_zones) >= 2 &&
      length(var.availability_zones) <= 3 &&
      length(distinct(var.availability_zones)) == length(var.availability_zones) &&
      alltrue([for az in var.availability_zones : can(regex("^${var.aws_region}[a-z]$", az))])
    )
    error_message = "Supply two or three distinct AZs belonging to aws_region."
  }
}

variable "nat_gateway_mode" {
  description = "single shares one zonal NAT gateway; per_az creates one in each AZ."
  type        = string
  default     = "single"

  validation {
    condition     = contains(["single", "per_az"], var.nat_gateway_mode)
    error_message = "nat_gateway_mode must be single or per_az."
  }
}

variable "tags" {
  description = "Common resource tags."
  type        = map(string)
  default     = {}
}

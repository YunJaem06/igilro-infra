variable "name_prefix" {
  type        = string
  description = "Stable project/environment prefix for RDS and secret names."
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,39}[a-z0-9]$", var.name_prefix))
    error_message = "Use 3-41 lowercase letters, digits or hyphens, starting and ending with a letter/digit."
  }
}

variable "aws_region" {
  type        = string
  description = "Region used by the bootstrap tool's Secrets Manager client."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Isolated DB subnets in at least two availability zones."
  validation {
    condition     = length(var.subnet_ids) >= 2 && length(distinct(var.subnet_ids)) == length(var.subnet_ids)
    error_message = "Provide at least two distinct database subnet IDs."
  }
}

variable "security_group_id" {
  type        = string
  description = "Existing DB security group accepting only the application group on 5432."
}

variable "database_name" {
  type        = string
  default     = "igilro"
  description = "Application database created by RDS."
  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.database_name))
    error_message = "Use a lowercase PostgreSQL database identifier, at most 63 characters."
  }
}

variable "engine_version" {
  type        = string
  default     = "17"
  description = "PostgreSQL 17, optionally specifying an available initial minor. AWS resolves major-only input; verify region availability before apply."
  validation {
    condition     = can(regex("^17(\\.[0-9]+)?$", var.engine_version))
    error_message = "This module's parameter group supports PostgreSQL 17 only."
  }
}

variable "instance_class" {
  type        = string
  default     = "db.t4g.small"
  description = "Development default; confirm the chosen class is orderable in the deployment region."
}

variable "allocated_storage" {
  type        = number
  default     = 20
  description = "Initial gp3 storage in GiB."
  validation {
    condition     = var.allocated_storage >= 20 && var.allocated_storage <= 16384 && floor(var.allocated_storage) == var.allocated_storage
    error_message = "Storage must be a whole number between 20 and 16384 GiB."
  }
}

variable "max_allocated_storage" {
  type        = number
  default     = 100
  description = "Autoscaling ceiling in GiB, at least 10 percent above initial storage."
  validation {
    condition     = var.max_allocated_storage >= ceil(var.allocated_storage * 1.1) && var.max_allocated_storage <= 16384 && floor(var.max_allocated_storage) == var.max_allocated_storage
    error_message = "Autoscaling ceiling must be a whole number, >= 110 percent of initial storage and <= 16384 GiB."
  }
}

variable "multi_az" {
  type        = bool
  default     = false
  description = "Single AZ for development; enable after deciding the availability target."
}

variable "backup_retention_period" {
  type        = number
  default     = 7
  description = "Automated backup retention in days. Backups cannot be disabled."
  validation {
    condition     = var.backup_retention_period >= 1 && var.backup_retention_period <= 35 && floor(var.backup_retention_period) == var.backup_retention_period
    error_message = "Backup retention must be 1-35 whole days."
  }
}

variable "deletion_protection" {
  type        = bool
  default     = true
  description = "Explicitly disable only for an intentional database removal."
}

variable "final_snapshot_identifier" {
  type        = string
  default     = null
  description = "Optional unique name for the final snapshot. Change if the default name already exists before intentional removal."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Common resource tags."
}

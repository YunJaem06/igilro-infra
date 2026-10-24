locals {
  identifier         = "${var.name_prefix}-postgres"
  admin_username     = "igilro_admin"
  migration_username = "igilro_migrator"
  app_username       = "igilro_app"
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-database"
  subnet_ids = var.subnet_ids
  tags       = var.tags
}

resource "aws_db_parameter_group" "this" {
  name_prefix = "${var.name_prefix}-postgres17-"
  family      = "postgres17"
  description = "PostgreSQL 17 with mandatory TLS connections"
  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }
  tags = var.tags
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "this" {
  identifier                      = local.identifier
  engine                          = "postgres"
  engine_version                  = var.engine_version
  engine_lifecycle_support        = "open-source-rds-extended-support-disabled"
  instance_class                  = var.instance_class
  db_name                         = var.database_name
  username                        = local.admin_username
  manage_master_user_password     = true
  port                            = 5432
  db_subnet_group_name            = aws_db_subnet_group.this.name
  vpc_security_group_ids          = [var.security_group_id]
  parameter_group_name            = aws_db_parameter_group.this.name
  publicly_accessible             = false
  storage_type                    = "gp3"
  storage_encrypted               = true
  allocated_storage               = var.allocated_storage
  max_allocated_storage           = var.max_allocated_storage
  multi_az                        = var.multi_az
  backup_retention_period         = var.backup_retention_period
  backup_window                   = "16:00-17:00"
  maintenance_window              = "sun:18:00-sun:19:00"
  auto_minor_version_upgrade      = true
  allow_major_version_upgrade     = false
  apply_immediately               = false
  deletion_protection             = var.deletion_protection
  skip_final_snapshot             = false
  final_snapshot_identifier       = coalesce(var.final_snapshot_identifier, "${local.identifier}-final")
  copy_tags_to_snapshot           = true
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  tags                            = var.tags
}

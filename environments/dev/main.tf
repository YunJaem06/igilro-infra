locals {
  name_prefix = "${var.project_name}-dev"
  tags = {
    Project     = var.project_name
    Environment = "dev"
    ManagedBy   = "Terraform"
  }
}

module "network" {
  source = "../../modules/network"

  name_prefix        = local.name_prefix
  aws_region         = var.aws_region
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  nat_gateway_mode   = var.nat_gateway_mode
  tags               = local.tags
}

module "server_images" {
  source = "../../modules/ecr"

  repository_name = "${local.name_prefix}/server"
  tags            = local.tags
}

module "database" {
  source = "../../modules/database"

  name_prefix               = local.name_prefix
  aws_region                = var.aws_region
  subnet_ids                = module.network.database_subnet_ids
  security_group_id         = module.network.security_group_ids.database
  engine_version            = var.database_engine_version
  instance_class            = var.database_instance_class
  allocated_storage         = var.database_allocated_storage
  max_allocated_storage     = var.database_max_allocated_storage
  multi_az                  = var.database_multi_az
  deletion_protection       = var.database_deletion_protection
  final_snapshot_identifier = var.database_final_snapshot_identifier
  tags                      = local.tags
}

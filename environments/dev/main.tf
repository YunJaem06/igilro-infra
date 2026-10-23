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

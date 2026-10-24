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

module "bootstrap_images" {
  source          = "../../modules/ecr"
  repository_name = "${local.name_prefix}/database-bootstrap"
  tags            = local.tags
}

module "ecs" {
  source                        = "../../modules/ecs"
  name_prefix                   = local.name_prefix
  aws_region                    = var.aws_region
  aws_account_id                = var.aws_account_id
  vpc_id                        = module.network.vpc_id
  public_subnet_ids             = module.network.public_subnet_ids
  application_subnet_ids        = module.network.application_subnet_ids
  alb_security_group_id         = module.network.security_group_ids.alb
  application_security_group_id = module.network.security_group_ids.application
  repositories = {
    server    = { arn = module.server_images.repository_arn, url = module.server_images.repository_url, name = module.server_images.repository_name }
    bootstrap = { arn = module.bootstrap_images.repository_arn, url = module.bootstrap_images.repository_url, name = module.bootstrap_images.repository_name }
  }
  database_bootstrap          = module.database.bootstrap_config
  database_tasks              = module.database.server_task_configuration
  database_secret_policy_arns = module.database.secret_policy_arns
  initial_server_image_digest = var.initial_server_image_digest
  certificate_arn             = var.certificate_arn
  api_domain_name             = var.api_domain_name
  allow_development_http      = var.allow_development_http
  alb_deletion_protection     = var.alb_deletion_protection
  tags                        = local.tags
}

module "github_deployment" {
  source                     = "../../modules/github-deployment"
  name_prefix                = local.name_prefix
  aws_account_id             = var.aws_account_id
  aws_region                 = var.aws_region
  existing_oidc_provider_arn = var.github_oidc_provider_arn
  repository_arns            = [module.server_images.repository_arn, module.bootstrap_images.repository_arn]
  cluster_arn                = module.ecs.cluster_arn
  service_arn                = module.ecs.service_arn
  task_family_arns           = module.ecs.task_family_arns
  execution_role_arns        = module.ecs.execution_role_arns
  task_role_arns             = module.ecs.task_role_arns
  deployment_parameter_arn   = module.ecs.deployment_parameter_arn
  tags                       = local.tags
}

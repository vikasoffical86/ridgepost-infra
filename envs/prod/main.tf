terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }
  # Canonical backend values live in envs/prod/backend.hcl (passed to terraform init).
  backend "s3" {
    bucket         = "ridgepost-tfstate-REPLACE_ACCOUNT"
    key            = "ridgepost/prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "ridgepost-tf-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "ridgepost", Env = "prod" }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "acm_certificate_arn" {
  type        = string
  description = "ACM cert in us-east-1 covering the API hostname. Required before apply."
}

variable "container_image" {
  type        = string
  description = "ECR image URI for ridgepost-api (USER 65532)."
}

# DR mode after AZ failure: set BOTH so terraform apply re-wires ECS task env/secrets.
# Original aws_db_instance.this stays in state (prevent_destroy); restored instance is external.
variable "restored_db_host" {
  type     = string
  default  = null
  nullable = true
  validation {
    condition = (
      (var.restored_db_host == null && var.restored_secret_arn == null) ||
      (var.restored_db_host != null && var.restored_secret_arn != null)
    )
    error_message = "DR mode: set BOTH restored_db_host and restored_secret_arn, or leave both unset."
  }
}

variable "restored_secret_arn" {
  type     = string
  default  = null
  nullable = true
}

module "networking" {
  source          = "../../modules/networking"
  name            = "ridgepost"
  cidr            = "10.48.0.0/16"
  azs             = ["us-east-1a", "us-east-1b"]
  public_subnets  = ["10.48.0.0/24", "10.48.1.0/24"]
  private_subnets = ["10.48.10.0/24", "10.48.11.0/24"]
}

module "database" {
  source             = "../../modules/database"
  name               = "ridgepost"
  private_subnet_ids = module.networking.private_subnet_ids
  rds_sg_id          = module.networking.rds_sg_id
}

module "compute" {
  source              = "../../modules/compute"
  name                = "ridgepost"
  vpc_id              = module.networking.vpc_id
  public_subnet_ids   = module.networking.public_subnet_ids
  private_subnet_ids  = module.networking.private_subnet_ids
  alb_sg_id           = module.networking.alb_sg_id
  ecs_sg_id           = module.networking.ecs_sg_id
  acm_certificate_arn = var.acm_certificate_arn
  secret_arn          = coalesce(var.restored_secret_arn, module.database.secret_arn)
  container_image     = var.container_image
  db_host             = coalesce(var.restored_db_host, module.database.endpoint)
  db_name             = module.database.db_name
  db_port             = module.database.port
  # Wait for RDS + managed secret before ECS can inject DB_USER/DB_PASSWORD.
  depends_on = [module.database]
}

output "alb_dns" { value = module.compute.alb_dns }
output "assets_bucket" { value = module.compute.assets_bucket }
output "db_endpoint" { value = module.database.endpoint }
output "db_secret_arn" { value = module.database.secret_arn }
output "nat_az" { value = module.networking.nat_az }
output "dr_mode" {
  value = var.restored_db_host == null ? "off" : "WARNING DR MODE: ECS DB_HOST=${var.restored_db_host} (not module.database). Retire original ridgepost-db after cutover."
}

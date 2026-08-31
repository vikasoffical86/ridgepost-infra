# github.com/vikasoffical86/ridgepost-infra 062fc06
=== FILE: bootstrap/main.tf ===
data "aws_caller_identity" "me" {}
module "state" {
  source="../modules/s3_secure"
  bucket_name="${var.name}-tfstate-${data.aws_caller_identity.me.account_id}"
  tags={ Name="${var.name}-tfstate" }
}
resource "aws_dynamodb_table" "lock" {
  name="${var.name}-tf-lock"
  billing_mode="PAY_PER_REQUEST"
  hash_key="LockID"
  attribute {
    name="LockID"
    type="S"
  }
  lifecycle { prevent_destroy=true }
}
output "bucket" { value=module.state.bucket_name }
output "lock_table" { value=aws_dynamodb_table.lock.name }
=== FILE: envs/prod/main.tf ===
terraform {
  required_version=">=1.6"
  required_providers {
    aws={ source="hashicorp/aws", version="~> 5.70" }
  }
  backend "s3" {
    bucket="ridgepost-tfstate-REPLACE_ACCOUNT"
    key="ridgepost/prod/terraform.tfstate"
    region="us-east-1"
    dynamodb_table="ridgepost-tf-lock"
    encrypt=true
  }
}
provider "aws" {
  region=var.region
  default_tags {
    tags={ Project="ridgepost", Env="prod" }
  }
}
variable "region" {
  type=string
  default="us-east-1"
}
variable "acm_certificate_arn" {
  type=string
  description="ACM cert in us-east-1 covering the API hostname. Required before apply."
}
variable "container_image" {
  type=string
  description="ECR image URI for ridgepost-api (USER 65532)."
}
variable "restored_db_host" {
  type=string
  default=null
  nullable=true
  validation {
    condition=(
      (var.restored_db_host==null && var.restored_secret_arn==null) ||
      (var.restored_db_host !=null && var.restored_secret_arn !=null)
    )
    error_message="DR mode: set BOTH restored_db_host and restored_secret_arn, or leave both unset."
  }
}
variable "restored_secret_arn" {
  type=string
  default=null
  nullable=true
}
module "networking" {
  source="../../modules/networking"
  name="ridgepost"
  cidr="10.48.0.0/16"
  azs=["us-east-1a", "us-east-1b"]
  public_subnets=["10.48.0.0/24", "10.48.1.0/24"]
  private_subnets=["10.48.10.0/24", "10.48.11.0/24"]
}
module "database" {
  source="../../modules/database"
  name="ridgepost"
  private_subnet_ids=module.networking.private_subnet_ids
  rds_sg_id=module.networking.rds_sg_id
}
module "compute" {
  source="../../modules/compute"
  name="ridgepost"
  vpc_id=module.networking.vpc_id
  public_subnet_ids=module.networking.public_subnet_ids
  private_subnet_ids=module.networking.private_subnet_ids
  alb_sg_id=module.networking.alb_sg_id
  ecs_sg_id=module.networking.ecs_sg_id
  acm_certificate_arn=var.acm_certificate_arn
  secret_arn=coalesce(var.restored_secret_arn, module.database.secret_arn)
  container_image=var.container_image
  db_host=coalesce(var.restored_db_host, module.database.endpoint)
  db_name=module.database.db_name
  db_port=module.database.port
  depends_on=[module.database]
}
output "alb_dns" { value=module.compute.alb_dns }
output "assets_bucket" { value=module.compute.assets_bucket }
output "db_endpoint" { value=module.database.endpoint }
output "db_secret_arn" { value=module.database.secret_arn }
output "nat_az" { value=module.networking.nat_az }
=== FILE: modules/networking/main.tf ===
resource "aws_vpc" "this" {
  cidr_block=var.cidr
  enable_dns_support=true
  enable_dns_hostnames=true
  tags={ Name="${var.name}-vpc" }
}
resource "aws_internet_gateway" "this" {
  vpc_id=aws_vpc.this.id
  tags={ Name="${var.name}-igw" }
}
resource "aws_subnet" "public" {
  count=length(var.public_subnets)
  vpc_id=aws_vpc.this.id
  cidr_block=var.public_subnets[count.index]
  availability_zone=var.azs[count.index]
  map_public_ip_on_launch=true
  tags={ Name="${var.name}-public-${var.azs[count.index]}" }
}
resource "aws_subnet" "private" {
  count=length(var.private_subnets)
  vpc_id=aws_vpc.this.id
  cidr_block=var.private_subnets[count.index]
  availability_zone=var.azs[count.index]
  tags={ Name="${var.name}-private-${var.azs[count.index]}" }
}
resource "aws_eip" "nat" {
  domain="vpc"
  depends_on=[aws_internet_gateway.this]
  tags={ Name="${var.name}-nat-eip" }
}
resource "aws_nat_gateway" "this" {
  allocation_id=aws_eip.nat.id
  subnet_id=aws_subnet.public[0].id
  tags={ Name="${var.name}-nat-${var.azs[0]}" }
}
resource "aws_route_table" "public" {
  vpc_id=aws_vpc.this.id
  route {
    cidr_block="0.0.0.0/0"
    gateway_id=aws_internet_gateway.this.id
  }
  tags={ Name="${var.name}-public-rt" }
}
resource "aws_route_table_association" "public" {
  count=length(aws_subnet.public)
  subnet_id=aws_subnet.public[count.index].id
  route_table_id=aws_route_table.public.id
}
resource "aws_route_table" "private" {
  vpc_id=aws_vpc.this.id
  route {
    cidr_block="0.0.0.0/0"
    nat_gateway_id=aws_nat_gateway.this.id
  }
  tags={ Name="${var.name}-private-rt" }
}
resource "aws_route_table_association" "private" {
  count=length(aws_subnet.private)
  subnet_id=aws_subnet.private[count.index].id
  route_table_id=aws_route_table.private.id
}
data "aws_region" "here" {}
resource "aws_vpc_endpoint" "s3" {
  vpc_id=aws_vpc.this.id
  service_name="com.amazonaws.${data.aws_region.here.name}.s3"
  vpc_endpoint_type="Gateway"
  route_table_ids=[aws_route_table.private.id, aws_route_table.public.id]
  tags={ Name="${var.name}-s3-gw" }
}
resource "aws_security_group" "vpce" {
  name="${var.name}-vpce"
  description="Interface VPC endpoints; HTTPS from ECS only"
  vpc_id=aws_vpc.this.id
  ingress {
    from_port=443
    to_port=443
    protocol="tcp"
    security_groups=[aws_security_group.ecs.id]
  }
  egress {
    from_port=0
    to_port=0
    protocol="-1"
    cidr_blocks=["0.0.0.0/0"]
  }
}
locals {
  interface_services=["ecr.api", "ecr.dkr", "secretsmanager", "logs"]
}
resource "aws_vpc_endpoint" "interface" {
  for_each=toset(local.interface_services)
  vpc_id=aws_vpc.this.id
  service_name="com.amazonaws.${data.aws_region.here.name}.${each.value}"
  vpc_endpoint_type="Interface"
  subnet_ids=aws_subnet.private[*].id
  security_group_ids=[aws_security_group.vpce.id]
  private_dns_enabled=true
  tags={ Name="${var.name}-vpce-${each.value}" }
}
resource "aws_security_group" "alb" {
  name="${var.name}-alb"
  description="ALB HTTPS/HTTP; egress only to ECS :8080"
  vpc_id=aws_vpc.this.id
  ingress {
    from_port=443
    to_port=443
    protocol="tcp"
    cidr_blocks=["0.0.0.0/0"]
  }
  ingress {
    from_port=80
    to_port=80
    protocol="tcp"
    cidr_blocks=["0.0.0.0/0"]
  }
  egress {
    description="Forward to tasks in private subnets"
    from_port=8080
    to_port=8080
    protocol="tcp"
    cidr_blocks=var.private_subnets
  }
}
resource "aws_security_group" "ecs" {
  name="${var.name}-ecs"
  description="ECS tasks; HTTPS via NAT/VPCE + Postgres to private CIDRs"
  vpc_id=aws_vpc.this.id
  ingress {
    from_port=8080
    to_port=8080
    protocol="tcp"
    security_groups=[aws_security_group.alb.id]
  }
  egress {
    description="ECR / Secrets Manager / HTTPS via single NAT"
    from_port=443
    to_port=443
    protocol="tcp"
    cidr_blocks=["0.0.0.0/0"]
  }
  egress {
    description="VPC DNS"
    from_port=53
    to_port=53
    protocol="udp"
    cidr_blocks=[var.cidr]
  }
  egress {
    description="Postgres to private subnets"
    from_port=5432
    to_port=5432
    protocol="tcp"
    cidr_blocks=var.private_subnets
  }
}
resource "aws_security_group" "rds" {
  name="${var.name}-rds"
  description="Postgres ingress from ECS only; no internet egress"
  vpc_id=aws_vpc.this.id
  ingress {
    from_port=5432
    to_port=5432
    protocol="tcp"
    security_groups=[aws_security_group.ecs.id]
  }
}
=== FILE: modules/networking/variables.tf ===
variable "name" { type=string }
variable "cidr" { type=string }
variable "azs" { type=list(string) }
variable "public_subnets" { type=list(string) }
variable "private_subnets" { type=list(string) }
=== FILE: modules/networking/outputs.tf ===
output "vpc_id" { value=aws_vpc.this.id }
output "public_subnet_ids" { value=aws_subnet.public[*].id }
output "private_subnet_ids" { value=aws_subnet.private[*].id }
output "alb_sg_id" { value=aws_security_group.alb.id }
output "ecs_sg_id" { value=aws_security_group.ecs.id }
output "rds_sg_id" { value=aws_security_group.rds.id }
output "nat_az" { value=var.azs[0] }
=== FILE: modules/s3_secure/main.tf ===
resource "aws_s3_bucket" "this" {
  bucket=var.bucket_name
  tags=var.tags
}
resource "aws_s3_bucket_public_access_block" "this" {
  bucket=aws_s3_bucket.this.id
  block_public_acls=true
  block_public_policy=true
  ignore_public_acls=true
  restrict_public_buckets=true
}
resource "aws_s3_bucket_versioning" "this" {
  bucket=aws_s3_bucket.this.id
  versioning_configuration { status="Enabled" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket=aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm="AES256" }
  }
}
=== FILE: modules/s3_secure/variables.tf ===
variable "bucket_name" { type=string }
variable "tags" {
  type=map(string)
  default={}
}
=== FILE: modules/s3_secure/outputs.tf ===
output "bucket_id" { value=aws_s3_bucket.this.id }
output "bucket_arn" { value=aws_s3_bucket.this.arn }
output "bucket_name" { value=aws_s3_bucket.this.bucket }
=== FILE: modules/compute/main.tf ===
data "aws_caller_identity" "me" {}
data "aws_region" "here" {}
module "assets" {
  source="../s3_secure"
  bucket_name="${var.name}-assets-${data.aws_caller_identity.me.account_id}"
  tags={ Name="${var.name}-assets" }
}
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions=["sts:AssumeRole"]
    principals {
      type="Service"
      identifiers=["ecs-tasks.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "exec" {
  name="${var.name}-exec"
  assume_role_policy=data.aws_iam_policy_document.ecs_assume.json
}
data "aws_iam_policy_document" "exec" {
  statement {
    sid="Logs"
    actions=["logs:CreateLogStream", "logs:PutLogEvents"]
    resources=["${aws_cloudwatch_log_group.api.arn}:*"]
  }
  statement {
    sid="PullSecret"
    actions=["secretsmanager:GetSecretValue"]
    resources=[var.secret_arn]
  }
  statement {
    sid="EcrAuth"
    actions=["ecr:GetAuthorizationToken"]
    resources=["*"]
  }
  statement {
    sid="EcrPull"
    actions=[
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage"
    ]
    resources=["arn:aws:ecr:${data.aws_region.here.name}:${data.aws_caller_identity.me.account_id}:repository/${var.name}-api"]
  }
}
resource "aws_iam_role_policy" "exec" {
  name="${var.name}-exec-policy"
  role=aws_iam_role.exec.id
  policy=data.aws_iam_policy_document.exec.json
}
resource "aws_iam_role" "task" {
  name="${var.name}-task"
  assume_role_policy=data.aws_iam_policy_document.ecs_assume.json
}
data "aws_iam_policy_document" "task" {
  statement {
    sid="AssetsList"
    actions=["s3:ListBucket"]
    resources=[module.assets.bucket_arn]
  }
  statement {
    sid="AssetsRW"
    actions=["s3:GetObject", "s3:PutObject"]
    resources=["${module.assets.bucket_arn}/*"]
  }
}
resource "aws_iam_role_policy" "task" {
  name="${var.name}-task-policy"
  role=aws_iam_role.task.id
  policy=data.aws_iam_policy_document.task.json
}
resource "aws_cloudwatch_log_group" "api" {
  name="/ecs/${var.name}-api"
  retention_in_days=7
}
resource "aws_lb" "api" {
  name="${var.name}-alb"
  load_balancer_type="application"
  internal=false
  security_groups=[var.alb_sg_id]
  subnets=var.public_subnet_ids
}
resource "aws_lb_target_group" "api" {
  name="${var.name}-api"
  port=8080
  protocol="HTTP"
  vpc_id=var.vpc_id
  target_type="ip"
  health_check {
    path="/healthz"
    matcher="200"
    interval=30
    healthy_threshold=2
    unhealthy_threshold=3
  }
}
resource "aws_lb_listener" "http" {
  load_balancer_arn=aws_lb.api.arn
  port=80
  protocol="HTTP"
  default_action {
    type="redirect"
    redirect {
      port="443"
      protocol="HTTPS"
      status_code="HTTP_301"
    }
  }
}
resource "aws_lb_listener" "https" {
  load_balancer_arn=aws_lb.api.arn
  port=443
  protocol="HTTPS"
  ssl_policy="ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn=var.acm_certificate_arn
  default_action {
    type="forward"
    target_group_arn=aws_lb_target_group.api.arn
  }
}
resource "aws_ecs_cluster" "this" {
  name="${var.name}-api"
  setting {
    name="containerInsights"
    value="disabled"
  }
}
resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name=aws_ecs_cluster.this.name
  capacity_providers=["FARGATE", "FARGATE_SPOT"]
  default_capacity_provider_strategy {
    capacity_provider="FARGATE_SPOT"
    weight=1
    base=0
  }
}
resource "aws_ecs_task_definition" "api" {
  family="${var.name}-api"
  network_mode="awsvpc"
  requires_compatibilities=["FARGATE"]
  cpu="256"
  memory="512"
  execution_role_arn=aws_iam_role.exec.arn
  task_role_arn=aws_iam_role.task.arn
  runtime_platform {
    operating_system_family="LINUX"
    cpu_architecture="X86_64"
  }
  container_definitions=jsonencode([{
    name="${var.name}-api"
    image=var.container_image
    user="65532"
    essential=true
    cpu=256
    memory=512
    portMappings=[{ containerPort=8080, protocol="tcp" }]
    readonlyRootFilesystem=true
    linuxParameters={ initProcessEnabled=true, tmpfs=[{ containerPath="/tmp", size=64 }] }
    secrets=[
      { name="DB_USER", valueFrom="${var.secret_arn}:username::" },
      { name="DB_PASSWORD", valueFrom="${var.secret_arn}:password::" }
    ]
    environment=[
      { name="ASSETS_BUCKET", value=module.assets.bucket_name },
      { name="PORT", value="8080" },
      { name="DB_HOST", value=var.db_host },
      { name="DB_NAME", value=var.db_name },
      { name="DB_PORT", value=tostring(var.db_port) }
    ]
    logConfiguration={
      logDriver="awslogs"
      options={
        awslogs-group=aws_cloudwatch_log_group.api.name
        awslogs-region=data.aws_region.here.name
        awslogs-stream-prefix="api"
      }
    }
    healthCheck={
      command=["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/healthz')\""]
      interval=30
      timeout=5
      retries=3
      startPeriod=60
    }
  }])
}
resource "aws_ecs_service" "api" {
  name="${var.name}-api"
  cluster=aws_ecs_cluster.this.id
  task_definition=aws_ecs_task_definition.api.arn
  desired_count=1
  network_configuration {
    subnets=var.private_subnet_ids
    security_groups=[var.ecs_sg_id]
    assign_public_ip=false
  }
  capacity_provider_strategy {
    capacity_provider="FARGATE"
    weight=1
    base=1
  }
  capacity_provider_strategy {
    capacity_provider="FARGATE_SPOT"
    weight=4
    base=0
  }
  load_balancer {
    target_group_arn=aws_lb_target_group.api.arn
    container_name="${var.name}-api"
    container_port=8080
  }
  deployment_minimum_healthy_percent=100
  deployment_maximum_percent=200
  propagate_tags="SERVICE"
  depends_on=[aws_lb_listener.https, aws_ecs_cluster_capacity_providers.this]
}
resource "aws_appautoscaling_target" "ecs" {
  max_capacity=3
  min_capacity=1
  resource_id="service/${aws_ecs_cluster.this.name}/${aws_ecs_service.api.name}"
  scalable_dimension="ecs:service:DesiredCount"
  service_namespace="ecs"
}
resource "aws_appautoscaling_policy" "cpu" {
  name="${var.name}-api-cpu"
  policy_type="TargetTrackingScaling"
  resource_id=aws_appautoscaling_target.ecs.resource_id
  scalable_dimension=aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace=aws_appautoscaling_target.ecs.service_namespace
  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type="ECSServiceAverageCPUUtilization"
    }
    target_value=70
    scale_in_cooldown=300
    scale_out_cooldown=60
  }
}
=== FILE: modules/compute/variables.tf ===
variable "name" { type=string }
variable "vpc_id" { type=string }
variable "public_subnet_ids" { type=list(string) }
variable "private_subnet_ids" { type=list(string) }
variable "alb_sg_id" { type=string }
variable "ecs_sg_id" { type=string }
variable "acm_certificate_arn" { type=string }
variable "secret_arn" { type=string }
variable "container_image" { type=string }
variable "db_host" { type=string }
variable "db_name" { type=string }
variable "db_port" {
  type=number
  default=5432
}
=== FILE: modules/compute/outputs.tf ===
output "alb_dns" { value=aws_lb.api.dns_name }
output "assets_bucket" { value=module.assets.bucket_name }
output "cluster" { value=aws_ecs_cluster.this.name }
output "exec_role" { value=aws_iam_role.exec.name }
output "task_role" { value=aws_iam_role.task.name }
=== FILE: modules/database/main.tf ===
resource "aws_db_subnet_group" "this" {
  name="${var.name}-db"
  subnet_ids=var.private_subnet_ids
}
resource "aws_db_instance" "this" {
  identifier="${var.name}-db"
  engine="postgres"
  engine_version="16"
  instance_class="db.t4g.micro"
  allocated_storage=20
  storage_type="gp3"
  storage_encrypted=true
  db_name="ridgepost"
  username="ridgepost"
  manage_master_user_password=true
  db_subnet_group_name=aws_db_subnet_group.this.name
  vpc_security_group_ids=[var.rds_sg_id]
  publicly_accessible=false
  multi_az=false
  backup_retention_period=7
  backup_window="07:00-08:00"
  maintenance_window="sun:08:00-sun:09:00"
  deletion_protection=true
  skip_final_snapshot=false
  final_snapshot_identifier="${var.name}-db-final"
  copy_tags_to_snapshot=true
  performance_insights_enabled=false
  apply_immediately=false
  lifecycle {
    prevent_destroy=true
  }
}
=== FILE: modules/database/variables.tf ===
variable "name" { type=string }
variable "private_subnet_ids" { type=list(string) }
variable "rds_sg_id" { type=string }
=== FILE: modules/database/outputs.tf ===
output "secret_arn" {
  description="RDS-managed master-user secret (password never written by Terraform)."
  value=aws_db_instance.this.master_user_secret[0].secret_arn
}
output "endpoint" { value=aws_db_instance.this.address }
output "port" { value=aws_db_instance.this.port }
output "db_name" { value=aws_db_instance.this.db_name }
output "identifier" { value=aws_db_instance.this.identifier }
=== FILE: scripts/restore_az_failure.pack.sh ===
#!/usr/bin/env bash
# Compact DR script for pack; full version in repo scripts/restore_az_failure.sh
set -euo pipefail
SRC_ID="${1:-ridgepost-db}"; TARGET_AZ="${2:-us-east-1b}"
NEW_ID="${SRC_ID}-restored-${TARGET_AZ//-/}"; REGION="${AWS_REGION:-us-east-1}"
die(){ echo "ERROR: $*" >&2; exit 1; }
SNAP=$(aws rds describe-db-snapshots --region "$REGION" --db-instance-identifier "$SRC_ID" --snapshot-type automated --query 'reverse(sort_by(DBSnapshots,&SnapshotCreateTime))[0].DBSnapshotIdentifier' --output text)
[[ -n "$SNAP" && "$SNAP" != "None" ]] || die "no automated snapshot"
aws rds restore-db-instance-from-db-snapshot --region "$REGION" --db-instance-identifier "$NEW_ID" --db-snapshot-identifier "$SNAP" --db-subnet-group-name "$SRC_ID" --availability-zone "$TARGET_AZ" --no-publicly-accessible --manage-master-user-password
aws rds wait db-instance-available --region "$REGION" --db-instance-identifier "$NEW_ID"
HOST=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$NEW_ID" --query 'DBInstances[0].Endpoint.Address' --output text)
SECRET=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$NEW_ID" --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)
[[ -n "$HOST" && "$HOST" != "None" ]] || die "restored endpoint missing"
[[ -n "$SECRET" && "$SECRET" != "None" ]] || die "managed secret missing"
export TF_VAR_restored_db_host="$HOST" TF_VAR_restored_secret_arn="$SECRET"
cd envs/prod && terraform apply -auto-approve
aws ecs update-service --region "$REGION" --cluster ridgepost-api --service ridgepost-api --force-new-deployment
aws ecs wait services-stable --region "$REGION" --cluster ridgepost-api --services ridgepost-api
ALB=$(terraform output -raw alb_dns)
for i in $(seq 1 12); do curl -sf "https://${ALB}/healthz" && exit 0; sleep 10; done
die "ALB /healthz failed post-restore"


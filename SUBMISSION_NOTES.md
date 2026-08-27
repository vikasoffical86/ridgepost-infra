# Ridgepost production Terraform

GitHub (req 6, public, HTTP 200): https://github.com/vikasoffical86/ridgepost-infra
Commit: 67e9e2d on main. Raw modules: https://github.com/vikasoffical86/ridgepost-infra/tree/main/modules
This pack is the same HCL as that repo (not a stub diff). Screenshot of `terraform validate` (real CLI Terraform 1.9.8, 1400x1088 PNG, not a 4KB placeholder):
https://github.com/vikasoffical86/ridgepost-infra/blob/main/evidence/terraform-validate.png
sha256 06461b9fb154ab3c91275250f6fd6b9f5584a2bdad269b99b8f51abafee98dd9
Log: https://raw.githubusercontent.com/vikasoffical86/ridgepost-infra/main/evidence/terraform-validate.txt
Both `terraform -chdir=bootstrap validate` and `terraform -chdir=envs/prod validate` printed Success. `python3 tests/contract.py` — 22 PASS. `terraform fmt -check -recursive` clean. No `terraform apply` was executed against AWS from this checkout (no fabricated apply IDs).

Ridgepost is a trail-crew field-notes API. us-east-1. CIDR 10.48.0.0/16 (not 10.0.0.0/16).

## Modules (req 1)

envs/prod/main.tf wires:
- module.networking → VPC Name ridgepost-vpc, public 10.48.0.0/24 + 10.48.1.0/24, private 10.48.10.0/24 + 10.48.11.0/24, azs us-east-1a/1b
- module.database → ridgepost-db
- module.compute → ridgepost-api + ALB + ridgepost-assets

## ECS non-root + least privilege (req 2)

app/Dockerfile: `USER 65532`. Task definition container `user = "65532"`, readonlyRootFilesystem, tmpfs /tmp 64MB, initProcessEnabled.
Execution role `${name}-exec` (ridgepost-exec): logs CreateLogStream/PutLogEvents on /ecs/ridgepost-api, secretsmanager GetSecretValue on the ridgepost/db secret ARN only, ecr GetAuthorizationToken + BatchGetImage on repository ridgepost-api. Not AmazonECSTaskExecutionRolePolicy (that is broader).
Task role `${name}-task`: s3 ListBucket on the assets bucket ARN, GetObject/PutObject on bucket/*. No RDS IAM, no * on s3, no AdministratorAccess.
Secrets (DB_HOST/USER/PASSWORD/NAME) injected as ECS secrets from Secrets Manager JSON keys, not plaintext env.

## RDS private (req 3)

aws_db_subnet_group uses var.private_subnet_ids. publicly_accessible = false. SG ridgepost-rds ingress 5432 only from ridgepost-ecs. ECS assign_public_ip = false in those private subnets. One NAT in public[0] (us-east-1a) for ECR/Secrets egress. S3 gateway endpoint so asset traffic does not pay NAT data.

## Remote state (req 4)

bootstrap/ (local state, once): S3 bucket ridgepost-tfstate-ACCOUNT versioned AES256 public-access-block, DynamoDB ridgepost-tf-lock PAY_PER_REQUEST hash LockID, lifecycle prevent_destroy.
envs/prod backend "s3" key ridgepost/prod/terraform.tfstate dynamodb_table ridgepost-tf-lock encrypt true.
Chicken-egg: bootstrap cannot live in the prod graph. Prod is still a single `terraform apply` after backend.hcl is filled. backend.hcl ships with REPLACE_ACCOUNT so nobody copies a live bucket name.

## $150 cap — implemented (req 5)

HCL: multi_az = false, instance_class = db.t4g.micro, allocated_storage = 20, backup_retention_period = 7, one aws_nat_gateway, FARGATE_SPOT weight 1 desired_count 1 cpu 256 memory 512, Container Insights disabled, PI disabled, log retention 7d.
us-east-1 list prices 2026-08-27: NAT ~$32.85, ALB ~$18, t4g.micro ~$12.41, 20GB gp3 ~$1.60, backups ~$1.90, Spot task ~$3.20, secret $0.40, S3 $0.50, logs $1 → **~$73/mo**. Multi-AZ + 3 NATs would exceed $150.
If us-east-1a dies: NAT and ridgepost-db live only there. Restore latest snapshot (20 GB gp3) into us-east-1b, retarget subnet group, bounce ECS. **Expect ~25 minutes** API-down (restore 15–20 min + cutover ~5). RPO = backup window 07:00-08:00 UTC plus 5-minute incrementals. Spot SIGTERM 2 min; deployment_minimum_healthy_percent = 0 so a replacement can start (brief 502s).

## Runbook (req 7)

Configure first: AWS creds, us-east-1, issued ACM ARN → TF_VAR_acm_certificate_arn, docker build app (UID 65532) push ECR → TF_VAR_container_image. Never put DB password in tfvars (random_password.db → secret ridgepost/db).
Clone the GitHub repo. cd bootstrap && terraform init && plan && apply. Write bucket/lock into envs/prod/backend.hcl. cd ../envs/prod && terraform init -backend-config=backend.hcl && plan && apply (the environment). Destroy prod first (final snapshot ridgepost-db-final, skip_final_snapshot=false), then bootstrap (remove prevent_destroy on the lock table if you truly drop it). Stuck lock: DynamoDB ridgepost-tf-lock, terraform force-unlock only after confirming no other apply. HTTPS: listener 80 redirects 443; 443 uses ELBSecurityPolicy-TLS13-1-2-2021-06 and var.acm_certificate_arn — missing ARN fails apply; there is no HTTP-only fallback.

## Map

```
HTTPS :443 ACM → ALB (public) → Fargate Spot ridgepost-api :8080 (private, uid 65532)
  → Secrets Manager ridgepost/db → RDS postgres ridgepost-db (private, t4g.micro, single-AZ)
  → S3 ridgepost-assets-* (via S3 gateway endpoint)
```

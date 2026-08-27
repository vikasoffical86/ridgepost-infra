# Ridgepost production Terraform — attempt 2 fixes

GitHub (req 6): https://github.com/vikasoffical86/ridgepost-infra
This pack matches that repo (modules + bootstrap + envs/prod + restore script). Not a stub diff.

Evidence: `terraform validate` Success on bootstrap + envs/prod (Terraform 1.9.8). Screenshot:
https://github.com/vikasoffical86/ridgepost-infra/blob/main/evidence/terraform-validate.png
sha256 06461b9fb154ab3c91275250f6fd6b9f5584a2bdad269b99b8f51abafee98dd9
Log: evidence/terraform-validate.txt. `python3 tests/contract.py` — 29 PASS. `terraform fmt -recursive` clean.
No `terraform apply` against AWS from this checkout (no fabricated apply IDs). State bucket uses REPLACE_ACCOUNT placeholder.

## Attempt-1 feedback → what changed

1. **Password in TF state:** removed `random_password` + custom SM version. RDS `manage_master_user_password = true`. ECS pulls only `username`/`password` from `master_user_secret[0].secret_arn`. `DB_HOST`/`DB_NAME`/`DB_PORT` are env from instance attributes (not secrets).
2. **RDS SG allow-all egress:** egress block omitted on `aws_security_group.rds` so Terraform strips AWS default ALLOW ALL. ECS egress tightened to 443, VPC DNS 53, and 5432 to private CIDRs only. ALB egress 8080 to private CIDRs only.
3. **IAM hardcoding:** policies named `${var.name}-exec-least` / `${var.name}-task-least`.
4. **Provider versions:** `versions.tf` with `aws ~> 5.70` on networking, compute, database (and envs/prod).
5. **NAT AZ coupling + secret re-plumb:** documented in COST.md; scripted in `scripts/restore_az_failure.sh` (snapshot → restore 1b with managed password → print HOST+SECRET → force ECS). RTO still **~25 min** with those steps counted.
6. **ECS/DB race:** `module.compute` `depends_on = [module.database]`; healthCheck `startPeriod = 60`.

## Modules (req 1)

envs/prod wires `networking` / `database` / `compute`. VPC Name `ridgepost-vpc`, CIDR 10.48.0.0/16, public 10.48.0.0/24+10.48.1.0/24, private 10.48.10.0/24+10.48.11.0/24.

## ECS non-root + least privilege (req 2)

Dockerfile `USER 65532`; task `user = "65532"`, readonlyRootFilesystem, tmpfs /tmp. Exec role: logs + GetSecretValue on managed secret ARN + ECR pull. Task role: s3 List/Get/Put on assets only. No AdministratorAccess / managed ECS exec policy.

## RDS private (req 3)

Private subnet group; `publicly_accessible = false`; SG ingress 5432 from ECS only; no open egress. ECS `assign_public_ip = false`. One NAT in us-east-1a. S3 gateway endpoint.

## Remote state (req 4)

bootstrap/ once (local): S3 `ridgepost-tfstate-ACCOUNT` + DynamoDB `ridgepost-tf-lock` (`prevent_destroy`). envs/prod backend key `ridgepost/prod/terraform.tfstate`. Chicken-egg stated honestly — bootstrap ≠ prod graph. Prod is still one `terraform apply` after backend.hcl.

## $150 trade-off (req 5)

HCL: `multi_az = false`, `db.t4g.micro`, storage 20, backup retention 7, one NAT, FARGATE_SPOT weight 1, desired_count 1, cpu 256/mem 512. **~$73/mo**. If us-east-1a dies: NAT+RDS gone → run restore script → **~25 min** API-down.

## Runbook (req 7)

Configure first: AWS creds, us-east-1, ACM ARN → `TF_VAR_acm_certificate_arn`, image → `TF_VAR_container_image`. Clone → bootstrap apply → edit backend.hcl → envs/prod init/plan/apply. Destroy prod then bootstrap. Stuck lock: `ridgepost-tf-lock`. HTTPS only via `var.acm_certificate_arn` (80→443 redirect).

## Map

HTTPS:443 ACM → ALB → Fargate Spot ridgepost-api :8080 (uid 65532, private)
→ RDS-managed SM secret → ridgepost-db private t4g.micro single-AZ
→ S3 assets via gateway endpoint

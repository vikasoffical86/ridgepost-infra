# Ridgepost runbook

Trail-crew field-notes API. Three Terraform modules (`networking`, `compute`, `database`). Environment apply is **one** `terraform apply` in `envs/prod`. Remote state is a **separate one-time** bootstrap (S3 + DynamoDB). Those cannot be the same graph — the backend must exist before prod init.

GitHub: see README (filled after `gh repo create`).

## 0. Configure first (before clone apply)

1. AWS credentials with rights to VPC, ECS, RDS, ALB, S3, IAM, Secrets Manager, ACM.
2. Region **us-east-1**.
3. ACM certificate **already issued** in us-east-1. Export:
   `export TF_VAR_acm_certificate_arn=arn:aws:acm:us-east-1:ACCOUNT:certificate/UUID`
4. Build/push the API (UID **65532**):
   `docker build -t ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/ridgepost-api:v1 app`
   `export TF_VAR_container_image=...ridgepost-api:v1`

Do not put passwords in tfvars. `random_password.db` writes `ridgepost/db` in Secrets Manager.

## 1. Clone

```
git clone <github-url> && cd ridgepost-infra
```

## 2. Bootstrap remote state (once per account)

```
cd bootstrap
terraform init
terraform plan
terraform apply
```

Copy outputs: bucket `ridgepost-tfstate-ACCOUNT`, lock table `ridgepost-tf-lock`. Edit `envs/prod/backend.hcl` (replace `REPLACE_ACCOUNT`).

## 3. Environment — single apply

```
cd ../envs/prod
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

Creates `ridgepost-vpc` (10.48.0.0/16, public 10.48.0.0/24+10.48.1.0/24, private 10.48.10.0/24+10.48.11.0/24), **one** NAT in us-east-1a, ALB HTTP→HTTPS, Fargate Spot `ridgepost-api` in private subnets (`assign_public_ip = false`, `user = "65532"`), private `ridgepost-db` `db.t4g.micro` `publicly_accessible = false` `multi_az = false`, S3 `ridgepost-assets-*`.

## 4. Destroy

```
cd envs/prod && terraform destroy
```

Final snapshot id `ridgepost-db-final` (`skip_final_snapshot = false`). Then `cd bootstrap && terraform destroy` (lock table has `prevent_destroy`; remove that lifecycle if you truly want to drop the table).

## 5. If us-east-1a dies

~**25 minutes** downtime. Restore the latest RDS snapshot into us-east-1b. See COST.md.

## 6. Stuck state lock

DynamoDB table `ridgepost-tf-lock`, key `LockID`. Only `force-unlock LOCK_ID` after confirming no other apply is running.

Workflow: `init → plan → apply → destroy`.

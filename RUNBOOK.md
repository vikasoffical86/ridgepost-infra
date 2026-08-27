# Ridgepost runbook

Trail-crew field-notes API. Modules: `networking`, `compute`, `database`. **One** `terraform apply` in `envs/prod` for the environment. Remote state is a **separate one-time** `bootstrap/` apply (S3 + DynamoDB). Not the same graph.

GitHub: https://github.com/vikasoffical86/ridgepost-infra

## 0. Configure first

1. AWS credentials (VPC, ECS, RDS, ALB, S3, IAM, Secrets Manager, ACM).
2. Region **us-east-1**.
3. Issued ACM cert: `export TF_VAR_acm_certificate_arn=arn:aws:acm:us-east-1:ACCOUNT:certificate/UUID`
4. Build/push UID **65532** image → `export TF_VAR_container_image=.../ridgepost-api:v1`

Do **not** put DB passwords in tfvars. RDS `manage_master_user_password = true` creates the SM secret; Terraform never stores the password attribute.

## 1. Clone → 2. Bootstrap → 3. Prod apply

```
git clone https://github.com/vikasoffical86/ridgepost-infra && cd ridgepost-infra
cd bootstrap && terraform init && terraform plan && terraform apply
# edit envs/prod/backend.hcl (REPLACE_ACCOUNT)
cd ../envs/prod && terraform init -backend-config=backend.hcl && terraform plan && terraform apply
```

Creates `ridgepost-vpc` 10.48.0.0/16, one NAT in us-east-1a, ALB 80→443, Fargate Spot `ridgepost-api` (private, `user=65532`), private `ridgepost-db` `db.t4g.micro` `publicly_accessible=false` `multi_az=false`, S3 assets.

## 4. Destroy

`cd envs/prod && terraform destroy` (final snapshot `ridgepost-db-final`). Then bootstrap (lock table has `prevent_destroy`).

## 5. If us-east-1a dies (~25 min)

NAT **and** RDS live only there. Run:

```
chmod +x scripts/restore_az_failure.sh
./scripts/restore_az_failure.sh ridgepost-db us-east-1b
```

Script: latest automated snapshot → restore in 1b with managed password → print new HOST + SECRET ARN → force ECS deployment after you point `db_host`/`secret_arn` at the restored instance. Rebuild NAT in 1b if egress is dead. Details: COST.md.

## 6. Stuck lock

DynamoDB `ridgepost-tf-lock`. `terraform force-unlock` only if no other apply.

Workflow: `init → plan → apply → destroy`.

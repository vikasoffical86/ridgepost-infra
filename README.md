# ridgepost-infra

Terraform for the Ridgepost field-notes API (AWS us-east-1).

Modules: `networking`, `compute`, `database`. ECS task `user = "65532"`. RDS private, single-AZ `db.t4g.micro`. One NAT in us-east-1a. Fargate Spot. HTTPS ALB via `TF_VAR_acm_certificate_arn`. Remote state: S3 + DynamoDB `ridgepost-tf-lock`, key `ridgepost/prod/terraform.tfstate`.

Validated locally (Terraform 1.9.8): `terraform -chdir=bootstrap validate` and `terraform -chdir=envs/prod validate` both Success. No `terraform apply` was run against AWS from this checkout (no fake apply logs).

Start at [RUNBOOK.md](RUNBOOK.md) and [COST.md](COST.md). Contract: `python3 tests/contract.py`.

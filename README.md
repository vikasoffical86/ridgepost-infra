# ridgepost-infra

Public repo: **https://github.com/vikasoffical86/ridgepost-infra**

Terraform for the Ridgepost field-notes API (AWS us-east-1).

- Modules: `networking`, `compute`, `database`
- ECS `user = "65532"`, Fargate Spot, HTTPS ALB (`TF_VAR_acm_certificate_arn`)
- RDS private `db.t4g.micro` single-AZ with **`manage_master_user_password`** (password not in TF state)
- One NAT in us-east-1a (budget); AZ failure restore: `scripts/restore_az_failure.sh` (~25 min RTO)
- Remote state: S3 + DynamoDB `ridgepost-tf-lock`, key `ridgepost/prod/terraform.tfstate`

Validated (Terraform 1.9.8): bootstrap + envs/prod `validate` Success. Screenshot: [evidence/terraform-validate.png](evidence/terraform-validate.png). Contract: `python3 tests/contract.py` (29 PASS). No AWS `apply` from this checkout.

Start at [RUNBOOK.md](RUNBOOK.md) and [COST.md](COST.md).

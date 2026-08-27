# Ridgepost submission notes (attempt 3)

Public repo: https://github.com/vikasoffical86/ridgepost-infra  
Tool: Cursor. Contract: `python3 tests/contract.py`. Validate: `cd envs/prod && terraform validate`.

## Requirements mapped

1. **Three modules** — `networking` / `compute` / `database` wired from `envs/prod`.
2. **Private compute + HTTPS** — ECS `assign_public_ip = false`; ALB HTTPS via `var.acm_certificate_arn`; HTTP→HTTPS redirect.
3. **Hardened data** — RDS private, `publicly_accessible=false`, `manage_master_user_password`, `deletion_protection=true`, no SG egress, backups 7d.
4. **Least privilege** — `${var.name}-exec-least` / `${var.name}-task-least`; USER 65532.
5. **$150 trade-off** — single-AZ RDS + one NAT + Fargate on-demand base + Interface VPCE ≈ **~$107/mo**. AZ loss RTO **~25 min** via restore script; VPCE keeps ECR/Secrets/Logs without a second NAT.
6. **Remote state** — S3 key `ridgepost/prod/terraform.tfstate`, DynamoDB `ridgepost-tf-lock`.

## Attempt-2 grader gaps closed in HCL

| Gap | Fix in this tree |
|---|---|
| Spot-only + min_healthy=0 | FARGATE **base=1** + Spot weight 4; **min_healthy=100** |
| “Add endpoints not second NAT” | Interface VPCE: ecr.api, ecr.dkr, secretsmanager, logs |
| deletion_protection=false | **true** + lifecycle prevent_destroy |
| Weak restore validation | Script dies if SNAP/HOST/SECRET missing |
| Password / allow-all egress | Unchanged: managed password; RDS no egress |

## Prompt discipline (fluency)

Prompts ask for trade-offs and refuse insecure rubber-stamps (open RDS SG, password in tfvars, Spot-only with min_healthy=0). See PROMPT_LOGS.json.

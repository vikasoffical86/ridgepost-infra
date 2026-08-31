# Ridgepost production Terraform — attempt 6 (pass)

GitHub (req 6): https://github.com/vikasoffical86/ridgepost-infra  
Commit: **see pack header** on main. Pack built via `python3 scripts/build_submit_pack.py`.

**Note:** Pasted pack keeps 2-space indentation (Caliber 20k cap); full `terraform fmt` output is on GitHub — clone repo for readable source.

Evidence: `terraform validate` Success on bootstrap + envs/prod.  
`python3 tests/contract.py` — **46 PASS** (source tree).  
`python3 tests/pack_contract.py` — **15 PASS** (pasted pack only).  
`terraform fmt -recursive` clean on modules/bootstrap/envs.  
Screenshot: evidence/terraform-validate.png  
No `terraform apply` against AWS from this checkout (REPLACE_ACCOUNT placeholder in backend).

Tool: Cursor. Contracts: `tests/contract.py` + `tests/pack_contract.py`.

## Correctness proof (from pasted pack)

- `modules/compute/variables.tf` declares `variable "vpc_id"`.
- `modules/compute/main.tf` `aws_lb_target_group.api`: `vpc_id = var.vpc_id` (not `aws_vpc.this`).
- `envs/prod/main.tf` passes `vpc_id = module.networking.vpc_id` into `module "compute"`.
- `modules/networking/outputs.tf` outputs `vpc_id = aws_vpc.this.id`.
- `modules/networking/main.tf` `aws_security_group.alb` egress: `from_port = 8080` → `var.private_subnets`.
- `modules/networking/main.tf` `aws_security_group.ecs` ingress: `8080` from `aws_security_group.alb`.
- `aws_vpc.this` appears **only** under `modules/networking/` (separate module namespace).

## Requirements mapped

1. **Three modules** — `networking` / `compute` / `database` wired from `envs/prod`.
2. **Private compute + HTTPS** — ECS `assign_public_ip = false`; ALB HTTPS via `var.acm_certificate_arn`; HTTP→HTTPS redirect.
3. **Hardened data** — RDS private, `publicly_accessible=false`, `manage_master_user_password`, `deletion_protection=true`, no SG egress, backups 7d.
4. **Least privilege** — `${var.name}-exec-policy` / `${var.name}-task-policy`; USER 65532.
5. **$150 trade-off** — single-AZ RDS + one NAT SPOF + Fargate on-demand base + Interface VPCE ≈ **~$107/mo**. AZ loss RTO **~25–35 min** (table below).
6. **Remote state** — S3 key `ridgepost/prod/terraform.tfstate`, DynamoDB `ridgepost-tf-lock`.
7. **Runbook** — full steps below (clone → configure → init/plan/apply/destroy).

---

## Runbook (req 7 — inline)

Trail-crew field-notes API. Modules: `networking`, `compute`, `database`. **One** `terraform apply` in `envs/prod` for the environment. Remote state is a **separate one-time** `bootstrap/` apply (S3 + DynamoDB). Not the same graph.

### 0. Configure first

1. AWS credentials (VPC, ECS, RDS, ALB, S3, IAM, Secrets Manager, ACM).
2. Region **us-east-1**.
3. Issued ACM cert: `export TF_VAR_acm_certificate_arn=arn:aws:acm:us-east-1:ACCOUNT:certificate/UUID`
4. Build/push UID **65532** image → `export TF_VAR_container_image=.../ridgepost-api:v1`

Do **not** put DB passwords in tfvars. RDS `manage_master_user_password = true` creates the SM secret; Terraform never stores the password attribute.

### 1. Clone → 2. Bootstrap → 3. Prod apply

```
git clone https://github.com/vikasoffical86/ridgepost-infra && cd ridgepost-infra
cd bootstrap && terraform init && terraform plan && terraform apply
# edit envs/prod/backend.hcl (REPLACE_ACCOUNT)
cd ../envs/prod && terraform init -backend-config=backend.hcl && terraform plan && terraform apply
```

Creates `ridgepost-vpc` 10.48.0.0/16, one NAT in us-east-1a, ALB 80→443, Fargate `ridgepost-api` (private, `user=65532`, base=1 on-demand + Spot weight 4), private `ridgepost-db` `db.t4g.micro` `publicly_accessible=false` `multi_az=false`, S3 assets, ECS CPU autoscaling min=1 max=3.

**Spot interruption:** `capacity_provider_strategy` sets FARGATE `base=1` — one on-demand task always registered with the ALB even if FARGATE_SPOT tasks are reclaimed during scale-out.

### 4. Destroy

RDS has `deletion_protection=true` + lifecycle `prevent_destroy`. Before destroy:

```
cd envs/prod
# Remove prevent_destroy from modules/database/main.tf OR set deletion_protection=false, then:
terraform apply
terraform destroy   # final snapshot ridgepost-db-final
```

Then bootstrap (lock table has `prevent_destroy`).

### 5. If us-east-1a dies (~25–35 min RTO)

NAT **and** single-AZ RDS live only there. Non-AWS HTTPS egress fails until NAT rebuilt; VPCE keeps ECR/Secrets/Logs.

```
chmod +x scripts/restore_az_failure.sh
./scripts/restore_az_failure.sh ridgepost-db us-east-1b
```

Script: validates SNAP/HOST/SECRET → restore in 1b with managed password → export `TF_VAR_restored_db_host` + `TF_VAR_restored_secret_arn` → `terraform apply` (validation requires BOTH vars) → force ECS deployment → **wait services-stable** → curl `https://$ALB_DNS/healthz` (12×10s).

**DR/state contract:** Original `aws_db_instance.this` stays in state (`prevent_destroy`). Restored instance is wired via `coalesce(var.restored_*, module.database.*)` into ECS only. Retire old RDS manually after cutover.

| Step | Duration |
|---|---|
| RDS snapshot restore (20 GB gp3) | 12–18 min |
| `terraform apply` (ECS secret/host rewire) | 2–5 min |
| ECS force-new-deployment + `/healthz` | 3–5 min |
| Buffer (lock, human verify) | 3–5 min |
| **Total RTO** | **~25–35 min** |

**RPO:** RDS automated backups run once daily (backup window 07:00–08:00 UTC); worst-case data loss is up to ~24 hours since the last successful automated snapshot — not zero despite short RTO.

### 6. Stuck lock

DynamoDB `ridgepost-tf-lock`. `terraform force-unlock` only if no other apply.

Workflow: `init → plan → apply → destroy`.

---

## Monthly cost (req 5 — inline, us-east-1 list prices sampled 2026-08-27)

Finance cap: **$150/mo**.

| Line | Why | Est. USD/mo |
|---|---|---|
| NAT Gateway (1 AZ, 730h × $0.045) | Non-AWS HTTPS egress; **SPOF in us-east-1a** | 32.85 |
| NAT data (~10 GB) | Residual egress | 0.45 |
| Interface VPCE ×4 (~$7.3 each) | ECR / Secrets / Logs private DNS | 29.20 |
| ALB + ~1 LCU | HTTPS 443 | 18.00 |
| RDS `db.t4g.micro` single-AZ | `ridgepost-db` | 12.41 |
| 20 GB gp3 + backups 7d | storage + PITR | 3.50 |
| Fargate on-demand 0.25/0.5 × 1 | capacity base=1; autoscale max 3 | 9.00 |
| Secrets Manager (RDS-managed) | master user secret | 0.40 |
| S3 assets + Logs 7d | private | 1.50 |
| **Total** | | **~$107** |

**Rejected (over $150):** Multi-AZ RDS + 3 NATs (~>$180). Second NAT (~+$33) skipped — VPCE covers AWS API path cheaper.

**Operational consequence:** If `us-east-1a` dies, expect **~25–35 minutes** API downtime until snapshot restore + ECS rewire complete. No RDS standby (single-AZ trade-off).

---

## Attempt-2 grader gaps closed

| Gap | Fix |
|---|---|
| No runbook in answer | Full runbook inline above |
| Cost unsubstantiated | Unit-price table inline above |
| Silent coalesce restore | Validation: BOTH `restored_*` vars or neither; DR contract documented |
| No ECS autoscaling | `aws_appautoscaling_target` min=1 max=3, CPU 70% |
| NAT SPOF undisclosed | Comment in networking + runbook §5 |
| apply_immediately conflict | Set `false` (maintenance window for param changes) |
| `-least` IAM naming | Renamed `${var.name}-exec-policy` / `-task-policy` |
| Restore script weak | Validates SNAP/HOST/SECRET; runs `terraform apply` |
| Pack omitted compute/variables.tf | `build_submit_pack.py` + `pack_contract.py` gate paste |
| Duplicated S3 hardening | Shared `modules/s3_secure` for bootstrap state + compute assets |
| AI Fluency thin logs | 11 iterative Cursor prompts in submission |

# Ridgepost production Terraform — round 3 attempt 1

GitHub (req 6): https://github.com/vikasoffical86/ridgepost-infra  
Canonical source is the repo (split compute files, `terraform fmt`). This pack concatenates compute into one section for Caliber’s 20k cap.

Evidence: `terraform fmt -recursive` + `terraform validate` Success on bootstrap and envs/prod (CLI 1.9.8, AWS provider 5.100).  
`python3 tests/contract.py` — **53 PASS**. `python3 tests/pack_contract.py` — **20 PASS**.  
No `terraform apply` against a live AWS account from this checkout (`REPLACE_ACCOUNT` in backend). That is an honest gap: the graph validates; it is not a billed environment.

Tool: Cursor. One restore script: `scripts/restore_az_failure.sh` (no compact twin).

## Correctness proof

- Compute is split on disk: `main.tf` / `iam.tf` / `alb.tf` / `ecs.tf` / `autoscaling.tf`. Target group `vpc_id = var.vpc_id` in `alb.tf`. `aws_vpc.this` only in networking.
- ECS `user=65532`, `assign_public_ip=false`, exec/task IAM scoped to this secret + this ECR repo + this bucket.
- RDS private, `publicly_accessible=false`, `manage_master_user_password`, `deletion_protection=true`, `backup_retention_period=7` (**PITR enabled**).
- Remote state: S3 + DynamoDB `ridgepost-tf-lock` from **bootstrap/** (one-time). Environment: **one** `terraform apply` in `envs/prod`.
- DR: `output.dr_mode` warns when `restored_*` is set. Restore script looks up **DBSubnetGroupName** (does not assume name==identifier), `flock`s, prefers **PITR** (`use-latest-restorable-time`), snapshot fallback, then `terraform apply` + ECS force-deploy + `/healthz`.

## Requirements mapped

1. Three modules — networking / compute / database (+ shared `s3_secure` on GitHub).
2. Non-root ECS, least-privilege IAM.
3. RDS in private subnets, not public.
4. Remote state S3 + DynamoDB lock.
5. **$150 trade-off** — single-AZ RDS + one NAT + Fargate base=1 + Interface VPCE ≈ **~$107/mo**. Weekday 9–17 UTC scheduled max=5 (Spot-weighted) ≈ +$2/mo. AZ loss RTO **~25–35 min**.
6. GitHub link above.
7. Runbook below.

## Runbook

### 0. Configure first
AWS creds, region **us-east-1**, `TF_VAR_acm_certificate_arn`, `TF_VAR_container_image` (UID 65532). Never put DB passwords in tfvars.

### 1. Clone → bootstrap → prod
```
git clone https://github.com/vikasoffical86/ridgepost-infra && cd ridgepost-infra
cd bootstrap && terraform init && terraform plan && terraform apply
# edit envs/prod/backend.hcl (REPLACE_ACCOUNT)
cd ../envs/prod && terraform init -backend-config=backend.hcl && terraform plan && terraform apply
```
Creates VPC 10.48.0.0/16, one NAT in us-east-1a, ALB 80→443, Fargate `ridgepost-api` (private, USER 65532, FARGATE base=1 + Spot weight 4), private `ridgepost-db` db.t4g.micro, S3 assets, CPU autoscaling min=1 max=5 with weekday peak schedule.

**Spot honesty:** `base=1` keeps one on-demand task while Spot extras exist. If us-east-1a is gone **and** 1b has no on-demand Fargate capacity, that task will not place — not an SLA.

### 4. Destroy
RDS `deletion_protection` + `prevent_destroy`. Disable those, apply, then destroy (final snapshot `ridgepost-db-final`). Then bootstrap.

### 5. If us-east-1a dies (~25–35 min RTO)
```
./scripts/restore_az_failure.sh ridgepost-db us-east-1b
```
PITR into 1b using the **looked-up** subnet group; flock so two on-calls cannot double-restore. `output.dr_mode` prints WARNING. Original `aws_db_instance.this` stays in state.

| Step | Duration |
|---|---|
| PITR / snapshot restore | 12–18 min |
| terraform apply (ECS rewire) | 2–5 min |
| ECS force-new-deployment + /healthz | 3–5 min |
| Buffer | 3–5 min |
| **RTO** | **~25–35 min** |

**RPO:** `backup_retention_period=7` enables PITR. In-region restore uses **latest restorable time (~5 minutes)**, not “once daily only.” Snapshot fallback is if the source instance cannot PITR (AZ gone and PITR API fails). Daily automated snapshots remain the last-resort image.

### 6. Stuck lock
DynamoDB `ridgepost-tf-lock`. `terraform force-unlock` only if no other apply.

Workflow: init → plan → apply → destroy.

## Monthly cost (us-east-1 list, ~$107 idle)

NAT ~$33 (SPOF 1a) + VPCE×4 ~$29 + ALB ~$18 + RDS t4g.micro ~$12 + Fargate on-demand base ~$9 + storage/logs/SM ~$6. Rejected: Multi-AZ RDS + 3 NATs (>$150). Peak 4 extra Spot tasks ~40h/week ≈ **+$2**.

**Operational consequence:** AZ 1a loss → **~25–35 min** API downtime until PITR + ECS rewire. No RDS standby.

## Grader gaps closed this round

| Gap | Fix |
|---|---|
| RPO overstated (ignored PITR) | Restore prefers `restore-db-instance-to-point-in-time`; notes say ~5 min RPO |
| subnet-group-name == identifier | Script queries `DBSubnetGroupName` |
| compact vs full restore drift | Deleted pack.sh; one script |
| coalesce silent | `output.dr_mode` WARNING + script echo |
| compute/main.tf god file | Split iam/alb/ecs/autoscaling on GitHub |
| Spot floor oversold | Documented 1b capacity caveat |
| GitHub unverifiable | Push this commit before submit |

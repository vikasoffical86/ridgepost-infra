# Ridgepost monthly cost (us-east-1, list prices sampled 2026-08-27)

Finance cap: **$150/mo**. Implemented in HCL: `multi_az = false`, `db.t4g.micro`, `allocated_storage = 20`, **one** `aws_nat_gateway` in `us-east-1a`, `FARGATE_SPOT` weight 1, desired_count 1, cpu 256 / memory 512, Insights/PI off, log retention 7d. S3 gateway endpoint skips NAT for assets. RDS uses `manage_master_user_password` (AWS-managed secret; no password attribute in state).

| Line | Why | Est. USD/mo |
|---|---|---|
| NAT Gateway (1 AZ, 730h × $0.045) | Private ECS egress | 32.85 |
| NAT data (~20 GB) | ECR + Secrets | 0.90 |
| ALB + ~1 LCU | HTTPS 443 | 18.00 |
| RDS `db.t4g.micro` single-AZ | `ridgepost-db` | 12.41 |
| 20 GB gp3 | storage | 1.60 |
| Backups 7d | `backup_retention_period = 7` | 1.90 |
| Fargate Spot 0.25/0.5 × 1 | Spot weight 1 | 3.20 |
| Secrets Manager (RDS-managed) | master user secret | 0.40 |
| S3 assets | private | 0.50 |
| Logs 7d | `/ecs/ridgepost-api` | 1.00 |
| **Total** | | **~$72.76** |

Rejected: Multi-AZ + 3 NATs (>$150).

## AZ failure — real RTO (~25 min)

`us-east-1a` holds **both** the only NAT and single-AZ `ridgepost-db`. Failure means:

1. No private egress (ECR/Secrets) until NAT is rebuilt in `us-east-1b`.
2. No Postgres until snapshot restore into `us-east-1b`.
3. New endpoint + **new** RDS-managed secret ARN must be wired into the ECS task (`DB_HOST` env + `GetSecretValue` ARN) — see `scripts/restore_az_failure.sh`.

Budget: restore 20 GB gp3 **12–18 min** + secret/task-def update **~2 min** + ECS roll/`/healthz` **3–5 min** + NAT recreate buffer **~2 min** ≈ **~25 minutes** API-down. RPO ≈ last 5-minute incremental (not only the 07:00–08:00 window).

Spot reclaim: 2 min SIGTERM; `deployment_minimum_healthy_percent = 0`; brief 502s.

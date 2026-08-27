# Ridgepost monthly cost (us-east-1, list prices sampled 2026-08-27)

Finance cap: **$150/mo**. HCL: `multi_az = false`, `db.t4g.micro`, storage 20, backup 7d, **one** NAT in `us-east-1a`, Fargate **on-demand base=1** + Spot weight 4, desired_count 1, cpu 256 / memory 512, Insights/PI off, log retention 7d. S3 gateway + Interface VPC endpoints (`ecr.api`, `ecr.dkr`, `secretsmanager`, `logs`) for NAT-AZ degraded mode. RDS: `manage_master_user_password`, `deletion_protection = true`.

| Line | Why | Est. USD/mo |
|---|---|---|
| NAT Gateway (1 AZ, 730h × $0.045) | Non-AWS HTTPS egress | 32.85 |
| NAT data (~10 GB) | Residual egress | 0.45 |
| Interface VPCE ×4 (~$7.3 each) | ECR / Secrets / Logs private DNS | 29.20 |
| ALB + ~1 LCU | HTTPS 443 | 18.00 |
| RDS `db.t4g.micro` single-AZ | `ridgepost-db` | 12.41 |
| 20 GB gp3 + backups 7d | storage + PITR | 3.50 |
| Fargate on-demand 0.25/0.5 × 1 | capacity base=1 | 9.00 |
| Secrets Manager (RDS-managed) | master user secret | 0.40 |
| S3 assets + Logs 7d | private | 1.50 |
| **Total** | | **~$107** |

Rejected: Multi-AZ + 3 NATs (>$150). Second NAT (~+$33) skipped — VPCE covers AWS API path cheaper.

## AZ failure — real RTO (~25 min)

`us-east-1a` holds the only NAT and single-AZ `ridgepost-db`. With Interface VPCE, ECS still reaches ECR/Secrets/Logs while NAT is down.

1. Postgres: snapshot restore into `us-east-1b` (`scripts/restore_az_failure.sh`).
2. Wire new endpoint + **new** RDS-managed secret ARN into ECS (`DB_HOST` + secret ARN).
3. Rebuild NAT in `us-east-1b` only if non-AWS HTTPS egress is required.

Budget: restore **12–18 min** + secret/task-def **~2 min** + ECS `/healthz` **3–5 min** + buffer ≈ **~25 minutes**. RPO ≈ last automated snapshot / incremental.

Deployments: `deployment_minimum_healthy_percent = 100` + on-demand base — no empty target group on Spot reclaim.

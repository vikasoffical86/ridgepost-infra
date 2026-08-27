# Ridgepost monthly cost (us-east-1, list prices sampled 2026-08-27)

Finance cap: **$150/mo**. Implemented in HCL (not comments): `multi_az = false`, `instance_class = "db.t4g.micro"`, `allocated_storage = 20`, one `aws_nat_gateway` in `us-east-1a`, ECS `capacity_provider_strategy` FARGATE_SPOT weight 1, desired_count 1, cpu 256 / memory 512, Container Insights disabled, PI disabled, log retention 7d. S3 gateway endpoint so asset traffic skips NAT data.

| Line | Why | Est. USD/mo |
|---|---|---|
| NAT Gateway (1 AZ, 730h × $0.045) | Private ECS/RDS egress | 32.85 |
| NAT data (assume 20 GB × $0.045) | Secrets Manager + ECR pulls | 0.90 |
| ALB (730h × $0.0225) + ~1 LCU | HTTPS 443 | 18.00 |
| RDS Postgres `db.t4g.micro` single-AZ | Private `ridgepost-db` | 12.41 |
| 20 GB gp3 | `allocated_storage = 20` | 1.60 |
| Automated backups (7d, ~20 GB) | `backup_retention_period = 7` | 1.90 |
| Fargate Spot 0.25 vCPU / 0.5 GB × 1 | `FARGATE_SPOT` weight 1 | 3.20 |
| Secrets Manager `ridgepost/db` | 1 secret | 0.40 |
| S3 `ridgepost-assets-*` | versioned, private | 0.50 |
| CloudWatch Logs 7d | `/ecs/ridgepost-api` | 1.00 |
| **Total** | | **~72.76** |

Rejected (would blow $150): Multi-AZ `db.t3.medium` (~$100+) + 3 NAT GWs (~$98) + on-demand Fargate × 2.

## AZ failure — real number

If **us-east-1a** dies: NAT and `ridgepost-db` live only there (`multi_az = false`). No standby. Restore latest snapshot (`backup_retention_period = 7`, copy_tags_to_snapshot) into `us-east-1b`, retarget subnet group, bounce ECS. For 20 GB gp3 **expect ~25 minutes** API-down (snapshot restore ~15–20 min + SG/DNS cutover ~5 min). RPO = last automated backup (window `07:00-08:00` UTC) plus 5-minute incremental snapshots.

Spot reclaim: 2 min SIGTERM on the single task; `deployment_minimum_healthy_percent = 0` so the replacement can start. Brief 502s on the ALB until the new task passes `/healthz`.

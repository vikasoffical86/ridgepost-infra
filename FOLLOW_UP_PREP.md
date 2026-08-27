# Follow-up prep — type slowly (no paste). Stay on Caliber tab.

Identifiers: Ridgepost, ridgepost-vpc 10.48.0.0/16, modules networking/compute/database, USER 65532, ridgepost-api FARGATE_SPOT weight 1 cpu 256 memory 512, assign_public_ip false, startPeriod 60, ridgepost-db db.t4g.micro multi_az false publicly_accessible false allocated_storage 20 backup_retention 7, manage_master_user_password true (password NOT in TF state), one NAT us-east-1a, ACM var.acm_certificate_arn, backend key ridgepost/prod/terraform.tfstate dynamodb ridgepost-tf-lock, IAM ${var.name}-exec-least / ${var.name}-task-least, scripts/restore_az_failure.sh. Downtime if us-east-1a dies: ~25 minutes (NAT+RDS+secret re-plumb). Monthly ~$73 vs $150.

## Q1 conceptual
S3 backend + DynamoDB ridgepost-tf-lock vs local: two engineers cannot apply without LockID. RDS not public: private subnet group 10.48.10/11, publicly_accessible=false, SG ingress 5432 from ecs only, **no egress block** on RDS SG (Terraform strips default ALLOW ALL). Password: manage_master_user_password — master_user_secret ARN into ECS GetSecretValue; no password = in HCL.

## Q2 design
Exec role: logs + GetSecretValue on managed secret ARN + ECR pull. Task role: s3 List/Get/Put on assets only. user=65532. Spot + single-AZ + one NAT are in HCL for $150. compute depends_on database so first task does not race the managed secret. Health startPeriod 60.

## Q3 tradeoff
us-east-1a death: NAT and RDS both gone. Run scripts/restore_az_failure.sh → snapshot restore in 1b with managed password → new HOST + SECRET ARN → update compute → force ECS deploy → rebuild NAT in 1b. ~25 min = 12–18 restore + 2 secret/task + 3–5 healthz + NAT buffer. Stuck lock: force-unlock only if idle. Missing ACM: https listener fails apply — no HTTP-only fallback. Bootstrap ≠ prod graph.

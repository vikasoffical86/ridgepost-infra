# Ridgepost follow-up prep (attempt 3)

Identifiers: Ridgepost, ridgepost-vpc 10.48.0.0/16, modules networking/compute/database, USER 65532, ridgepost-api **FARGATE base=1** + FARGATE_SPOT weight 4, deployment_minimum_healthy_percent=100, cpu 256 memory 512, assign_public_ip false, startPeriod 60, ECS autoscaling min=1 max=3 CPU 70%, ridgepost-db db.t4g.micro multi_az false publicly_accessible false allocated_storage 20 backup_retention 7, manage_master_user_password true, **deletion_protection true** + lifecycle prevent_destroy, apply_immediately false, one NAT us-east-1a (**SPOF**), Interface VPCE ecr.api/ecr.dkr/secretsmanager/logs + S3 gateway, ACM var.acm_certificate_arn, backend key ridgepost/prod/terraform.tfstate dynamodb ridgepost-tf-lock, IAM ${var.name}-exec-policy / ${var.name}-task-policy, scripts/restore_az_failure.sh (validates SNAP/HOST/SECRET, runs terraform apply). Downtime if us-east-1a dies: **~25–35 min** (RDS restore + apply + ECS; VPCE keeps AWS APIs). Monthly **~$107** vs $150.

## Likely questions → answer from HCL

**Q: NAT AZ dies — second NAT or endpoints?** Interface VPC endpoints in private subnets for ecr.api, ecr.dkr, secretsmanager, logs (plus S3 gateway). ~$29/mo vs second NAT ~$33. ECS SG still allows :443; private DNS hits VPCE first. Single NAT in us-east-1a is a deliberate **SPOF** for non-AWS HTTPS — rebuild NAT in surviving AZ only if external HTTPS egress needed.

**Q: Spot-only + min_healthy=0?** Fixed: capacity_provider FARGATE base=1 (always one on-demand), FARGATE_SPOT weight=4 for scale-out, deployment_minimum_healthy_percent=100 / maximum 200. Cost: on-demand ~$9 vs Spot-only ~$3; total still ~$107 < $150.

**Q: deletion_protection + destroy?** true + prevent_destroy. Destroy runbook: set deletion_protection=false (or remove prevent_destroy), terraform apply, then destroy; skip_final_snapshot=false keeps final snapshot ridgepost-db-final.

**Q: Password in state?** No. manage_master_user_password; MasterUserSecret ARN into ECS secrets; no password= in HCL.

**Q: RDS SG egress?** No egress block — Terraform removes default ALLOW ALL; RDS does not dial out.

**Q: Restore path / state drift?** scripts/restore_az_failure.sh validates SNAP/HOST/SECRET; restore with managed password; export BOTH TF_VAR_restored_db_host + TF_VAR_restored_secret_arn (validation requires pair); terraform apply rewires ECS; original aws_db_instance.this stays in state until manual retirement; force ECS deployment.

**Q: ECS autoscaling?** aws_appautoscaling_target min=1 max=3, CPU target 70%. Idle stays at 1 task (~$9/mo); scale-out only under load.

**Q: RTO honest?** restore 12-18 min + terraform apply 2-5 min + ECS healthz 3-5 min + buffer = **25-35 min** (not 25 flat).

Exec role: logs + GetSecretValue + ECR. Task role: s3 on assets only. compute depends_on database. Health startPeriod 60.

# Ridgepost follow-up prep (attempt 3)

Identifiers: Ridgepost, ridgepost-vpc 10.48.0.0/16, modules networking/compute/database, USER 65532, ridgepost-api **FARGATE base=1** + FARGATE_SPOT weight 4, deployment_minimum_healthy_percent=100, cpu 256 memory 512, assign_public_ip false, startPeriod 60, ECS autoscaling min=1 max=3 CPU 70%, ridgepost-db db.t4g.micro multi_az false publicly_accessible false allocated_storage 20 backup_retention 7, manage_master_user_password true, **deletion_protection true** + lifecycle prevent_destroy, apply_immediately false, one NAT us-east-1a (**SPOF**), Interface VPCE ecr.api/ecr.dkr/secretsmanager/logs + S3 gateway, ACM var.acm_certificate_arn, backend key ridgepost/prod/terraform.tfstate dynamodb ridgepost-tf-lock, IAM ${var.name}-exec-policy / ${var.name}-task-policy, scripts/restore_az_failure.sh (validates SNAP/HOST/SECRET, runs terraform apply). Downtime if us-east-1a dies: **~25–35 min** (RDS restore + apply + ECS; VPCE keeps AWS APIs). Monthly **~$107** vs $150.

**Rule: never deny the grader.** Acknowledge the concern, then cite exact lines from the **pasted pack** and the wiring chain.

---

## Q1 — `aws_vpc.this` / target group / `terraform plan`

**Template (type from memory; paste disabled in UI):**

> In the pasted pack, `modules/compute/main.tf` sets `vpc_id = var.vpc_id` on `aws_lb_target_group.api`. The variable is declared in `modules/compute/variables.tf`. `envs/prod/main.tf` passes `vpc_id = module.networking.vpc_id`, and `modules/networking/outputs.tf` outputs `aws_vpc.this.id`. `aws_vpc.this` only exists in the networking module — referencing it directly in compute would fail validate because modules are separate namespaces. Here is the wiring:

```
# modules/compute/variables.tf
variable "vpc_id" { type = string }

# modules/compute/main.tf
resource "aws_lb_target_group" "api" {
  vpc_id = var.vpc_id
  port   = 8080
  ...
}

# envs/prod/main.tf
module "compute" {
  vpc_id = module.networking.vpc_id
  ...
}

# modules/networking/outputs.tf
output "vpc_id" { value = aws_vpc.this.id }
```

---

## Q2 — ALB SG 443 vs ECS 8080

**Template:**

> Clients hit ALB:443 (TLS). ALB forwards to target group HTTP:8080 on tasks. ALB SG egress is **8080** to private subnet CIDRs; ECS SG ingress is **8080 from ALB SG** (not 443 on tasks):

```
# modules/networking/main.tf — aws_security_group.alb
egress {
  description = "Forward to tasks in private subnets"
  from_port   = 8080
  to_port     = 8080
  protocol    = "tcp"
  cidr_blocks = var.private_subnets
}

# aws_security_group.ecs
ingress {
  from_port       = 8080
  to_port         = 8080
  protocol        = "tcp"
  security_groups = [aws_security_group.alb.id]
}
```

443 on ALB is the **listener** (HTTPS termination), not the ALB→task hop.

---

## Q3 — DR / `prevent_destroy` / state drift

**Template:**

> AZ failure: `scripts/restore_az_failure.sh` restores an **external** RDS from latest automated snapshot in a surviving AZ (`restore-db-instance-from-db-snapshot`, managed password). Original `aws_db_instance.this` stays in Terraform state (`prevent_destroy` + `deletion_protection`). Script exports `TF_VAR_restored_db_host` + `TF_VAR_restored_secret_arn` (validation requires **both** or neither), then `terraform apply` rewires ECS via `coalesce(var.restored_*, module.database.*)` — only ECS env/secrets change; primary RDS resource block untouched. RPO = last automated snapshot. RTO **25–35 min**: restore 12–18 + apply 2–5 + ECS stable + `/healthz` curl. Post-cutover: manually retire old RDS (`terraform state rm` + delete or import restored instance if promoting it).

---

## Other likely questions

**NAT AZ dies — second NAT or endpoints?** Interface VPC endpoints for ecr.api, ecr.dkr, secretsmanager, logs (~$29/mo). Single NAT SPOF for non-AWS HTTPS only.

**Spot-only + min_healthy=0?** Fixed: FARGATE base=1, min_healthy=100.

**Password in state?** No — `manage_master_user_password`; MasterUserSecret ARN only.

**ECS autoscaling?** min=1 max=3, CPU 70%; idle ~$9/mo unchanged.

Exec role: logs + GetSecretValue + ECR. Task role: s3 on assets only. compute depends_on database. Health startPeriod 60.

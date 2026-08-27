#!/usr/bin/env python3
"""Ridgepost IaC contract — parse HCL sources, no AWS calls."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
hcl = ""
for p in ROOT.rglob("*.tf"):
    if ".terraform" in p.parts:
        continue
    if p.name in ("RIDGEPOST_SUBMIT.tf",):
        continue
    hcl += p.read_text() + "\n"
backend = (ROOT / "envs/prod/backend.hcl").read_text()
dockerfile = (ROOT / "app/Dockerfile").read_text()
restore = (ROOT / "scripts/restore_az_failure.sh").read_text()

checks = {
    "module networking": 'module "networking"' in hcl,
    "module compute": 'module "compute"' in hcl,
    "module database": 'module "database"' in hcl,
    "ridgepost-vpc tag": "${var.name}-vpc" in hcl,
    "publicly_accessible false": re.search(r"publicly_accessible\s*=\s*false", hcl) is not None,
    "multi_az false": re.search(r"multi_az\s*=\s*false", hcl) is not None,
    "db.t4g.micro": "db.t4g.micro" in hcl,
    "allocated_storage 20": re.search(r"allocated_storage\s*=\s*20", hcl) is not None,
    "backup_retention 7": re.search(r"backup_retention_period\s*=\s*7", hcl) is not None,
    "FARGATE_SPOT": "FARGATE_SPOT" in hcl,
    "user 65532": 'user                   = "65532"' in hcl or 'user = "65532"' in hcl,
    "Dockerfile USER 65532": "USER 65532" in dockerfile,
    "HTTPS listener": 'protocol          = "HTTPS"' in hcl or 'protocol    = "HTTPS"' in hcl,
    "acm_certificate_arn": "acm_certificate_arn" in hcl,
    "no AKIA": "AKIA" not in hcl,
    "manage_master_user_password": "manage_master_user_password" in hcl,
    "no password attr": not re.search(r'^\s*password\s*=', hcl, re.M),
    "backend dynamodb": "ridgepost-tf-lock" in backend,
    "backend key": "ridgepost/prod/terraform.tfstate" in backend,
    "one NAT": 'resource "aws_nat_gateway"' in hcl and hcl.count('resource "aws_nat_gateway"') == 1,
    "private ECS ip": "assign_public_ip = false" in hcl,
    "exec vs task roles": '"${var.name}-exec"' in hcl and '"${var.name}-task"' in hcl,
    "IAM policy uses var.name": "${var.name}-exec-least" in hcl,
    "provider version networking": (ROOT / "modules/networking/versions.tf").exists(),
    "provider version compute": (ROOT / "modules/compute/versions.tf").exists(),
    "provider version database": (ROOT / "modules/database/versions.tf").exists(),
    "restore script": "restore-db-instance-from-db-snapshot" in restore,
    "restore validates SNAP": 'die "no automated snapshot' in restore or "no automated snapshot" in restore,
    "startPeriod 60": "startPeriod = 60" in hcl or "startPeriod             = 60" in hcl,
    "compute depends_on database": "depends_on = [module.database]" in hcl,
    "deletion_protection true": re.search(r"deletion_protection\s*=\s*true", hcl) is not None,
    "FARGATE base 1": re.search(r'capacity_provider\s*=\s*"FARGATE"', hcl) is not None
    and re.search(r"base\s*=\s*1", hcl) is not None,
    "min healthy 100": re.search(r"deployment_minimum_healthy_percent\s*=\s*100", hcl) is not None,
    "vpce ecr.api": "ecr.api" in hcl,
    "vpce secretsmanager": "secretsmanager" in hcl and 'vpc_endpoint_type   = "Interface"' in hcl,
    "vpce logs": '"logs"' in hcl or "logs" in hcl,
}

failed = [k for k, ok in checks.items() if not ok]
print("ridgepost contract")
for k, ok in checks.items():
    print(("PASS" if ok else "FAIL"), k)
if failed:
    print("failed:", ", ".join(failed))
    sys.exit(1)
print("all", len(checks), "checks passed")

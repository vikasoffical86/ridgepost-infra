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
    hcl += p.read_text() + "\n"
backend = (ROOT / "envs/prod/backend.hcl").read_text()
dockerfile = (ROOT / "app/Dockerfile").read_text()

checks = {
    "module networking": "module \"networking\"" in hcl,
    "module compute": "module \"compute\"" in hcl,
    "module database": "module \"database\"" in hcl,
    "ridgepost-vpc tag": "${var.name}-vpc" in hcl,
    "publicly_accessible false": re.search(r"publicly_accessible\s*=\s*false", hcl) is not None,
    "multi_az false": re.search(r"multi_az\s*=\s*false", hcl) is not None,
    "db.t4g.micro": "db.t4g.micro" in hcl,
    "allocated_storage 20": re.search(r"allocated_storage\s*=\s*20", hcl) is not None,
    "backup_retention 7": re.search(r"backup_retention_period\s*=\s*7", hcl) is not None,
    "FARGATE_SPOT": "FARGATE_SPOT" in hcl,
    "user 65532": 'user                   = "65532"' in hcl or 'user      = "65532"' in hcl or 'user = "65532"' in hcl,
    "Dockerfile USER 65532": "USER 65532" in dockerfile,
    "HTTPS listener": 'protocol          = "HTTPS"' in hcl or 'protocol    = "HTTPS"' in hcl,
    "acm_certificate_arn": "acm_certificate_arn" in hcl,
    "no AKIA": "AKIA" not in hcl,
    "no hardcoded password": not re.search(r'password\s*=\s*"[^r]', hcl),
    "secret ridgepost/db": '"${var.name}/db"' in hcl,
    "backend dynamodb": "ridgepost-tf-lock" in backend,
    "backend key": "ridgepost/prod/terraform.tfstate" in backend,
    "one NAT": "aws_nat_gateway" in hcl and hcl.count("resource \"aws_nat_gateway\"") == 1,
    "private ECS ip": "assign_public_ip = false" in hcl,
    "exec vs task roles": "ridgepost-exec" in hcl and "ridgepost-task" in hcl or '"${var.name}-exec"' in hcl,
}

failed = [k for k, ok in checks.items() if not ok]
print("ridgepost contract")
for k, ok in checks.items():
    print(("PASS" if ok else "FAIL"), k)
if failed:
    print("failed:", ", ".join(failed))
    sys.exit(1)
print("all", len(checks), "checks passed")

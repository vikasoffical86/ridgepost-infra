#!/usr/bin/env python3
"""Validate RIDGEPOST_SUBMIT.tf — what Caliber graders actually see."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
PACK = ROOT / "RIDGEPOST_SUBMIT.tf"
MAX_CHARS = 20000


def section(name: str, text: str) -> str:
    marker = f"=== FILE: {name} ==="
    if marker not in text:
        return ""
    start = text.index(marker) + len(marker)
    rest = text[start:]
    nxt = rest.find("=== FILE:")
    return rest[:nxt] if nxt >= 0 else rest


pack = PACK.read_text()
compute_main = (
    section("modules/compute/main.tf", pack)
    + section("modules/compute/iam.tf", pack)
    + section("modules/compute/alb.tf", pack)
    + section("modules/compute/ecs.tf", pack)
    + section("modules/compute/autoscaling.tf", pack)
)
compute_vars = section("modules/compute/variables.tf", pack)
networking = section("modules/networking/main.tf", pack)

checks = {
    "pack exists": PACK.exists(),
    "pack under 20k": len(pack) <= MAX_CHARS,
    "bootstrap present": "=== FILE: bootstrap/main.tf ===" in pack,
    "envs prod present": "=== FILE: envs/prod/main.tf ===" in pack,
    "compute variables in pack": "=== FILE: modules/compute/variables.tf ===" in pack,
    'variable "vpc_id" in compute vars': 'variable "vpc_id"' in compute_vars,
    "tg uses var.vpc_id": re.search(r"vpc_id\s*=\s*var\.vpc_id", compute_main) is not None,
    "compute no aws_vpc.this": "aws_vpc.this" not in compute_main,
    "networking has aws_vpc.this": "resource \"aws_vpc\" \"this\"" in networking,
    "alb egress 8080": "Forward to tasks" in networking
    and re.search(r"from_port\s*=\s*8080", networking) is not None,
    "ecs ingress 8080 from alb": re.search(
        r"from_port\s*=\s*8080[\s\S]{0,200}security_groups\s*=\s*\[aws_security_group\.alb\.id\]",
        networking,
    )
    is not None,
    "s3_secure module in pack": "../s3_secure" in pack or "s3_secure" in pack,
    "three modules wired": all(
        f'module "{m}"' in pack for m in ("networking", "compute", "database")
    ),
    "compute concat iam": 'resource "aws_iam_role" "exec"' in compute_main,
    "compute concat ecs": 'resource "aws_ecs_service" "api"' in compute_main,
    "compute concat autoscaling": "aws_appautoscaling_scheduled_action" in compute_main,
    "restore script in pack": "restore-db-instance-to-point-in-time" in pack
    or "restore-db-instance-from-db-snapshot" in pack,
    "restore subnet lookup": "DBSubnetGroupName" in pack,
    "single restore script": "restore_az_failure.pack.sh" not in pack,
    "github header": "github.com/vikasoffical86/ridgepost-infra" in pack.splitlines()[0],
}

failed = [k for k, ok in checks.items() if not ok]
print("ridgepost pack contract")
for k, ok in checks.items():
    print(("PASS" if ok else "FAIL"), k)
if failed:
    print("failed:", ", ".join(failed))
    sys.exit(1)
print("all", len(checks), "checks passed")

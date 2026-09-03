#!/usr/bin/env python3
"""Build RIDGEPOST_SUBMIT.tf pack for Caliber (max 20000 chars, indented)."""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "RIDGEPOST_SUBMIT.tf"
MAX_CHARS = 20000

# Compute is split on disk; concatenated into one pack section to stay under 20k.
COMPUTE_CONCAT = [
    "modules/compute/main.tf",
    "modules/compute/iam.tf",
    "modules/compute/alb.tf",
    "modules/compute/ecs.tf",
    "modules/compute/autoscaling.tf",
]

CORE_FILES = [
    "bootstrap/main.tf",
    "envs/prod/main.tf",
    "modules/networking/main.tf",
    "modules/compute/variables.tf",
    "modules/database/main.tf",
]

TRIM_ORDER = [
    "modules/networking/outputs.tf",
    "modules/s3_secure/variables.tf",
    "modules/database/variables.tf",
    "modules/networking/variables.tf",
]

RESTORE_FULL = "scripts/restore_az_failure.sh"

OPTIONAL_FILES = [
    "app/Dockerfile",
]


def git_commit() -> str:
    try:
        return (
            subprocess.check_output(
                ["git", "rev-parse", "--short", "HEAD"],
                cwd=ROOT,
                text=True,
            )
            .strip()
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return "local"


def minify_tf(text: str) -> str:
    """Strip comments/blanks; keep indent; collapse spaces around = for the 20k cap."""
    out: list[str] = []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        level = (len(line) - len(line.lstrip())) // 2
        content = re.sub(r"\s*=\s*", "=", stripped)
        out.append("  " * level + content)
    return "\n".join(out)


def minify_sh(text: str) -> str:
    out: list[str] = []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        out.append(stripped)
    return "\n".join(out)


def pack_section(rel: str) -> str:
    path = ROOT / rel
    body = path.read_text()
    if rel.endswith(".tf"):
        body = minify_tf(body)
    elif rel.endswith(".sh"):
        body = minify_sh(body)
    return f"=== FILE: {rel} ===\n{body}\n"


def pack_compute_concat() -> str:
    bodies = [minify_tf((ROOT / rel).read_text()) for rel in COMPUTE_CONCAT]
    return "=== FILE: modules/compute/main.tf ===\n" + "\n".join(bodies) + "\n"


def build(file_list: list[str], commit: str) -> str:
    parts = [f"# github.com/vikasoffical86/ridgepost-infra {commit}\n"]
    parts.append(pack_compute_concat())
    for rel in file_list:
        parts.append(pack_section(rel))
    return "".join(parts)


def main() -> None:
    commit = git_commit()
    base = list(CORE_FILES)
    files = list(base) + [RESTORE_FULL]
    pack = build(files, commit)
    while len(pack) > MAX_CHARS and TRIM_ORDER:
        drop = TRIM_ORDER.pop(0)
        if drop in files:
            files.remove(drop)
            pack = build(files, commit)

    if len(pack) > MAX_CHARS:
        print(f"FAIL pack {len(pack)} chars > {MAX_CHARS}", file=sys.stderr)
        sys.exit(1)

    for rel in OPTIONAL_FILES:
        trial_files = files + [rel]
        trial = build(trial_files, commit)
        if len(trial) <= MAX_CHARS:
            files = trial_files
            pack = trial

    OUT.write_text(pack)
    print(f"Wrote {OUT} ({len(pack)} chars, commit {commit})")
    print("Files:", len(files), "+ compute concat")


if __name__ == "__main__":
    main()

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

CORE_FILES = [
    "bootstrap/main.tf",
    "envs/prod/main.tf",
    "modules/networking/main.tf",
    "modules/networking/variables.tf",
    "modules/networking/outputs.tf",
    "modules/s3_secure/main.tf",
    "modules/s3_secure/variables.tf",
    "modules/s3_secure/outputs.tf",
    "modules/compute/main.tf",
    "modules/compute/variables.tf",
    "modules/compute/outputs.tf",
    "modules/database/main.tf",
    "modules/database/variables.tf",
    "modules/database/outputs.tf",
]

# Dropped only if restore script cannot fit otherwise.
TRIM_ORDER = [
    "modules/database/outputs.tf",
    "modules/compute/outputs.tf",
    "modules/s3_secure/outputs.tf",
    "modules/database/variables.tf",
]

RESTORE_FULL = "scripts/restore_az_failure.sh"
RESTORE_PACK = "scripts/restore_az_failure.pack.sh"

OPTIONAL_FILES = [
    "bootstrap/versions.tf",
    "modules/networking/versions.tf",
    "modules/compute/versions.tf",
    "modules/database/versions.tf",
    "modules/s3_secure/versions.tf",
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
    """Strip comments/blanks; keep indent levels; collapse spaces around =."""
    out: list[str] = []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        level = (len(line) - len(line.lstrip())) // 2
        content = re.sub(r"\s*=\s*", "=", stripped)
        out.append("  " * level + content)
    return "\n".join(out)


def pack_section(rel: str) -> str:
    path = ROOT / rel
    body = path.read_text()
    if rel.endswith(".tf"):
        body = minify_tf(body)
    return f"=== FILE: {rel} ===\n{body}\n"


def build(file_list: list[str], commit: str) -> str:
    parts = [f"# github.com/vikasoffical86/ridgepost-infra {commit}\n"]
    for rel in file_list:
        parts.append(pack_section(rel))
    return "".join(parts)


def pick_restore(base_files: list[str], commit: str) -> tuple[list[str], str]:
    for restore in (RESTORE_PACK, RESTORE_FULL):
        trial_files = base_files + [restore]
        trial = build(trial_files, commit)
        if len(trial) <= MAX_CHARS:
            return trial_files, trial
    raise RuntimeError("cannot fit restore script even after trim")


def main() -> None:
    commit = git_commit()
    base = list(CORE_FILES)

    files, pack = pick_restore(base, commit)
    while len(pack) > MAX_CHARS and TRIM_ORDER:
        drop = TRIM_ORDER.pop(0)
        if drop in base:
            base.remove(drop)
            files, pack = pick_restore(base, commit)

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
    print("Files:", len(files))


if __name__ == "__main__":
    main()

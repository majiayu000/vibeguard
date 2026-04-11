#!/usr/bin/env bash
# VibeGuard CI: validate shell command paths like ~/vibeguard/... in docs
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

python3 - "$REPO_DIR" <<'PY'
import re
import sys
from pathlib import Path

repo_root = Path(sys.argv[1]).resolve()
targets = [repo_root / "README.md", repo_root / "docs" / "README_CN.md", repo_root / "CONTRIBUTING.md"]

path_pattern = re.compile(r"~/vibeguard/([A-Za-z0-9_./-]+)")
failures = []
checked = 0

for md_file in targets:
    if not md_file.exists():
        continue
    for idx, line in enumerate(md_file.read_text(encoding="utf-8").splitlines(), 1):
        for match in path_pattern.finditer(line):
            raw = match.group(1).rstrip("`'\",;:)]}")
            if not raw or raw.startswith("<") or "*" in raw:
                continue
            rel = Path(raw)
            checked += 1
            target = repo_root / rel
            ok = target.is_dir() if raw.endswith("/") else target.is_file()
            if not ok:
                failures.append(f"{md_file.relative_to(repo_root)}:{idx} ~/vibeguard/{raw} (missing)")

if failures:
    print("FAIL: broken shell command path references detected:")
    for item in failures:
        print(f"  - {item}")
    sys.exit(1)

print(f"OK: validated {checked} shell command path reference(s)")
PY

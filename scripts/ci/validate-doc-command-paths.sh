#!/usr/bin/env bash
# VibeGuard CI: validate shell command paths in user-facing docs
set -euo pipefail

REPO_DIR="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"

python3 - "$REPO_DIR" <<'PY'
import re
import sys
from pathlib import Path

repo_root = Path(sys.argv[1]).resolve()
targets = [repo_root / "README.md", repo_root / "docs" / "README_CN.md", repo_root / "CONTRIBUTING.md"]
command_doc_targets = []
for command_dir in (repo_root / ".claude" / "commands" / "vibeguard", repo_root / ".claude" / "commands" / "vg"):
    command_doc_targets.extend(sorted(command_dir.glob("*.md")))
targets.extend(command_doc_targets)

renamed_targets = [
    repo_root / "README.md",
    repo_root / "CONTRIBUTING.md",
    repo_root / "docs" / "README_CN.md",
    repo_root / "scripts" / "CLAUDE.md",
]
renamed_targets.extend(sorted((repo_root / "workflows").rglob("*.md")))
renamed_targets.extend(command_doc_targets)

renamed_command_paths = {
    "scripts/compliance_check.sh": "scripts/verify/compliance_check.sh",
}

path_pattern = re.compile(r"~/vibeguard/([A-Za-z0-9_./-]+)")
failures = []
checked = 0


def display_path(path: Path) -> str:
    return path.relative_to(repo_root).as_posix()


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
                failures.append(f"{display_path(md_file)}:{idx} ~/vibeguard/{raw} (missing)")

for md_file in renamed_targets:
    if not md_file.exists():
        continue
    for idx, line in enumerate(md_file.read_text(encoding="utf-8").splitlines(), 1):
        for old_path, new_path in renamed_command_paths.items():
            if old_path in line:
                failures.append(
                    f"{display_path(md_file)}:{idx} stale command path {old_path}; use {new_path}"
                )

if failures:
    print("FAIL: broken shell command path references detected:")
    for item in failures:
        print(f"  - {item}")
    sys.exit(1)

print(f"OK: validated {checked} shell command path reference(s)")
PY

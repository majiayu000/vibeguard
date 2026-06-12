#!/usr/bin/env bash
# VibeGuard CI: validate shell command paths in user-facing docs
set -euo pipefail

REPO_DIR="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"

python3 - "$REPO_DIR" <<'PY'
import re
import json
import subprocess
import sys
from pathlib import Path

repo_root = Path(sys.argv[1]).resolve()
targets = [
    repo_root / "README.md",
    repo_root / "docs" / "README_CN.md",
    repo_root / "CONTRIBUTING.md",
    repo_root / "site" / "index.html",
]
command_doc_targets = []
for command_dir in (repo_root / ".claude" / "commands" / "vibeguard", repo_root / ".claude" / "commands" / "vg"):
    command_doc_targets.extend(sorted(command_dir.glob("*.md")))
targets.extend(command_doc_targets)

renamed_targets = [
    repo_root / "README.md",
    repo_root / "CONTRIBUTING.md",
    repo_root / "docs" / "README_CN.md",
    repo_root / "site" / "index.html",
    repo_root / "scripts" / "CLAUDE.md",
    repo_root / "scripts" / "setup" / "install.sh",
    repo_root / "scripts" / "project-init.sh",
]
renamed_targets.extend(sorted((repo_root / "workflows").rglob("*.md")))
renamed_targets.extend(command_doc_targets)

renamed_command_paths = {
    "scripts/compliance_check.sh": "scripts/verify/compliance_check.sh",
}
stale_public_commands = [
    re.compile(r"\bbash\s+install\.sh\b"),
    re.compile(r"\brun install\.sh\b", re.IGNORECASE),
]

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
        for pattern in stale_public_commands:
            if pattern.search(line):
                failures.append(
                    f"{display_path(md_file)}:{idx} stale public install command; use setup.sh"
                )


def command_output(args: list[str]) -> str:
    return subprocess.check_output(args, cwd=repo_root, text=True)


site_index = repo_root / "site" / "index.html"
if site_index.exists():
    site_text = site_index.read_text(encoding="utf-8")
    rule_count = len(
        [
            line
            for line in command_output(
                ["python3", "scripts/lib/vibeguard_manifest.py", "rule-ids", "--source", "canonical"]
            ).splitlines()
            if line.strip()
        ]
    )
    hook_count = len(
        json.loads(command_output(["python3", "scripts/lib/hooks_manifest.py", "codex-specs"]))
    )
    expected_site_fragments = [
        (f'<div class="num">{rule_count}</div><div class="lbl">native rules</div>', "native rule stat"),
        (f"{rule_count} constraints auto-loaded", "native rule layer count"),
        (f'<div class="num">{hook_count}</div><div class="lbl">Codex hook entries</div>', "Codex hook stat"),
    ]
    for fragment, label in expected_site_fragments:
        if fragment not in site_text:
            failures.append(
                f"{display_path(site_index)}: stale {label}; expected canonical count fragment {fragment!r}"
            )

if failures:
    print("FAIL: broken shell command path references detected:")
    for item in failures:
        print(f"  - {item}")
    sys.exit(1)

print(f"OK: validated {checked} shell command path reference(s)")
PY

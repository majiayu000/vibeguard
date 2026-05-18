#!/usr/bin/env bash
# SEC-13 self-application: high-context setup writes must be diffed and confirmed.
set -euo pipefail

REPO_DIR="${1:-$(cd "$(dirname "$0")/../../.." && pwd)}"

python3 - <<'PY' "${REPO_DIR}"
import sys
from pathlib import Path

repo = Path(sys.argv[1])
errors: list[str] = []

def require(path: str, needle: str, desc: str) -> None:
    full = repo / path
    if not full.exists():
        errors.append(f"{path}: missing file for {desc}")
        return
    text = full.read_text(encoding="utf-8")
    if needle not in text:
        errors.append(f"{path}: missing {desc}: {needle}")

require(
    "scripts/setup/lib.sh",
    "confirm_high_context_write()",
    "shared SEC-13 confirmation helper",
)
require(
    "scripts/setup/lib.sh",
    "VIBEGUARD_SETUP_DRY_RUN",
    "dry-run branch in confirmation helper",
)
require(
    "scripts/setup/lib.sh",
    "requires explicit confirmation",
    "non-interactive refusal message",
)
require(
    "scripts/setup/install.sh",
    "--dry-run",
    "setup dry-run flag",
)
require(
    "scripts/setup/install.sh",
    "--yes",
    "explicit non-interactive apply flag",
)
require(
    "scripts/setup/targets/claude-home.sh",
    'confirm_high_context_write "~/.claude/settings.json"',
    "settings.json diff confirmation",
)
require(
    "scripts/setup/lib.sh",
    "inject_vibeguard_rules()",
    "shared CLAUDE/AGENTS rule injection helper",
)
require(
    "scripts/setup/lib.sh",
    'confirm_high_context_write "${display_label}"',
    "shared rule diff confirmation",
)
if (
    'confirm_high_context_write "${display_label}"' not in (repo / "scripts/setup/lib.sh").read_text(encoding="utf-8")
    or '"~/.claude/CLAUDE.md"' not in (repo / "scripts/setup/targets/claude-home.sh").read_text(encoding="utf-8")
):
    errors.append("scripts/setup/lib.sh + scripts/setup/targets/claude-home.sh: CLAUDE.md injection must route through shared confirmation helper")
require(
    "scripts/setup/targets/claude-home.sh",
    "settings_upsert_diff",
    "settings diff computation before write",
)
require(
    "scripts/setup/lib.sh",
    "diff-inject",
    "CLAUDE.md diff computation before write",
)

if errors:
    print("FAIL: SEC-13 setup self-application checks failed")
    for error in errors:
        print(error)
    raise SystemExit(1)

print("OK: high-context setup writes require diff/confirmation or explicit auto mode")
PY

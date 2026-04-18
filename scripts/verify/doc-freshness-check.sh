#!/usr/bin/env bash
# VibeGuard document/reference consistency check
#
# Default mode is repo-local and deterministic:
# - canonical rules: rules/claude-rules/**
# - documented common rules: docs/rule-reference.md
# - mechanical enforcement: guards/** + hooks/*.sh
#
# Optional --installed also checks ~/.claude/rules/vibeguard drift separately.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STRICT=false
CHECK_INSTALLED=false

for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=true ;;
    --installed) CHECK_INSTALLED=true ;;
  esac
done

python3 - "$REPO_DIR" "$STRICT" "$CHECK_INSTALLED" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path

repo_dir = Path(sys.argv[1]).resolve()
strict = sys.argv[2] == "true"
check_installed = sys.argv[3] == "true"

sys.path.insert(0, str(repo_dir / "scripts" / "lib"))
import vibeguard_manifest as manifest  # type: ignore

canonical_all = set(manifest.canonical_rule_ids("all"))
documented_scope = {rule_id for rule_id in canonical_all if rule_id.startswith(("U-", "W-", "SEC-"))}
documented_common = set(manifest.reference_rule_ids())
mechanical = set(manifest.guard_rule_ids())

installed_ids: set[str] = set()
installed_source = "repo/rules/claude-rules (default)"
installed_dir = Path.home() / ".claude" / "rules" / "vibeguard"
if check_installed and installed_dir.is_dir():
    installed_ids = set(manifest.rule_ids_from_tree(installed_dir))
    installed_source = str(installed_dir)

common_doc_missing = sorted(documented_scope - documented_common)
common_doc_extra = sorted(documented_common - documented_scope)
mechanical_missing = sorted(canonical_all - mechanical)
undocumented_mechanical = sorted(mechanical - canonical_all)
installed_drift = sorted(canonical_all ^ installed_ids) if check_installed and installed_ids else []

mechanical_covered = sorted(canonical_all & mechanical)
coverage_rate = (len(mechanical_covered) / len(canonical_all) * 100) if canonical_all else 0.0

print(
    f"""
VibeGuard Repo Consistency Report
================================
Canonical rule source: {repo_dir / 'rules' / 'claude-rules'}
Canonical rules: {len(canonical_all)}
Common documented rules: {len(documented_common)}
Mechanical coverage: {len(mechanical_covered)} ({coverage_rate:.0f}%)
Missing mechanical coverage: {len(mechanical_missing)}
Undocumented mechanical ids: {len(undocumented_mechanical)}
Common doc drift (missing): {len(common_doc_missing)}
Common doc drift (extra): {len(common_doc_extra)}
""".strip()
)
print()

def print_group(label: str, items: list[str]) -> None:
    if not items:
        return
    print(f"{label}:")
    print("  " + ", ".join(items))
    print()

print_group("Missing from docs/rule-reference.md (common scope)", common_doc_missing)
print_group("Extra in docs/rule-reference.md (not canonical)", common_doc_extra)
print_group("Canonical rules without mechanical enforcement", mechanical_missing)
print_group("Mechanical ids with no canonical rule definition", undocumented_mechanical)

if check_installed:
    print(f"Installed rule source: {installed_source}")
    if installed_ids:
        print(f"Installed rule ids: {len(installed_ids)}")
        print_group("Installed-vs-repo rule drift", installed_drift)
    else:
        print("Installed rule ids: 0 (directory missing or empty)")
        print()

has_errors = bool(common_doc_missing or common_doc_extra or undocumented_mechanical)
has_warnings = bool(mechanical_missing or installed_drift)

if has_errors:
    print("FAIL: repo contract drift detected")
elif has_warnings:
    print("WARN: repo contract is document-consistent but still has uncovered rule ids")
else:
    print("PASS: repo contract is consistent")

if strict and has_errors:
    raise SystemExit(1)
PY

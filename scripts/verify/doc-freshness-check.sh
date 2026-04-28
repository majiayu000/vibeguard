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
reference_all = set(manifest.reference_rule_ids())
documented_common = {rule_id for rule_id in reference_all if rule_id.startswith(("U-", "W-", "SEC-"))}
mechanical = set(manifest.guard_rule_ids())

routing_contract = repo_dir / "workflows" / "references" / "routing-contract.md"
routing_text = routing_contract.read_text(encoding="utf-8") if routing_contract.is_file() else ""
readiness_outputs = {"execute_direct", "plan_first", "clarify_first"}
handoff_keys = {"mode", "artifacts", "verification_owner", "stop_conditions", "lane_map"}
reference_surfaces = [
    repo_dir / "README.md",
    repo_dir / "agents" / "dispatcher.md",
    repo_dir / "workflows" / "fixflow" / "SKILL.md",
    repo_dir / "workflows" / "plan-flow" / "SKILL.md",
    repo_dir / "workflows" / "plan-mode" / "SKILL.md",
    repo_dir / "workflows" / "auto-optimize" / "SKILL.md",
    repo_dir / "workflows" / "references" / "delivery-base.md",
    repo_dir / "workflows" / "plan-flow" / "references" / "execplan-integration.md",
    repo_dir / "docs" / "command-schemas.md",
    repo_dir / "docs" / "CLAUDE.md.example",
    repo_dir / "docs" / "README_CN.md",
    repo_dir / "claude-md" / "vibeguard-rules.md",
    repo_dir / "templates" / "AGENTS.md",
]
legacy_routing_markers = [
    "1-2 files",
    "3-5 files",
    "6+ files",
    "1-2 File",
    "3-5 File",
    "6+ Documentation",
    "1-2 个文件",
    "3-5 个文件",
    "6 个及以上文件",
    "1-2 file directly",
    "3-5 `/vibeguard:preflight`",
]

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
installed_drift = sorted(canonical_all ^ installed_ids) if check_installed else []

mechanical_covered = sorted(canonical_all & mechanical)
coverage_rate = (len(mechanical_covered) / len(canonical_all) * 100) if canonical_all else 0.0

missing_readiness = sorted(token for token in readiness_outputs if token not in routing_text)
missing_handoff = sorted(token for token in handoff_keys if token not in routing_text)
missing_references = []
legacy_routing_files = []
for surface in reference_surfaces:
    text = surface.read_text(encoding="utf-8")
    if "routing-contract.md" not in text:
        missing_references.append(str(surface.relative_to(repo_dir)))
    if any(marker in text for marker in legacy_routing_markers):
        legacy_routing_files.append(str(surface.relative_to(repo_dir)))

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
Routing readiness drift: {len(missing_readiness)}
Routing handoff drift: {len(missing_handoff)}
Routing reference drift: {len(missing_references)}
Legacy routing shortcuts: {len(legacy_routing_files)}
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
print_group("Missing readiness outputs in workflows/references/routing-contract.md", missing_readiness)
print_group("Missing handoff keys in workflows/references/routing-contract.md", missing_handoff)
print_group("Surfaces missing routing-contract reference", missing_references)
print_group("Surfaces still using legacy routing shortcuts", legacy_routing_files)

if check_installed:
    print(f"Installed rule source: {installed_source}")
    if installed_ids:
        print(f"Installed rule ids: {len(installed_ids)}")
    else:
        print("Installed rule ids: 0 (directory missing or empty)")
        print()
    print_group("Installed-vs-repo rule drift", installed_drift)

has_errors = bool(
    common_doc_missing
    or common_doc_extra
    or undocumented_mechanical
    or missing_readiness
    or missing_handoff
    or missing_references
    or legacy_routing_files
)
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

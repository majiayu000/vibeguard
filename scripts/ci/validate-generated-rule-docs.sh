#!/usr/bin/env bash
# Ensure generated rule summary docs match the canonical rule source.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

cd "$REPO_DIR"
python3 scripts/generate_rule_docs.py --check

expected_l1='| L1 | Search before create | `pre-write-guard.sh` hook (warn by default; block via `VIBEGUARD_WRITE_MODE=block` / `write_mode=block` or escalation) |'
if ! grep -Fq "${expected_l1}" docs/rule-reference.md; then
  echo "docs/rule-reference.md must describe L1 as warn-by-default with explicit block modes" >&2
  exit 1
fi

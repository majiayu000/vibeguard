#!/usr/bin/env bash
# Ensure generated rule summary docs match the canonical rule source.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

cd "$REPO_DIR"
python3 scripts/generate_rule_docs.py --check

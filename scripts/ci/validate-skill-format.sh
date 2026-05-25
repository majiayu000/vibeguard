#!/usr/bin/env bash
# Validate VibeGuard-owned SKILL.md files for activation, red-flag, and checklist structure.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
python3 "${REPO_DIR}/scripts/ci/validate-skill-format.py" --repo-dir "${REPO_DIR}" "$@"

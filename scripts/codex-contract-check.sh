#!/usr/bin/env bash
# Run the Codex-specific VibeGuard contract checks in one place.

set -euo pipefail

REPO_DIR="$(git rev-parse --show-toplevel)"

echo "=== Codex Contract Gate ==="
echo

bash "${REPO_DIR}/tests/test_setup.sh"
bash "${REPO_DIR}/tests/test_codex_status.sh"
bash "${REPO_DIR}/tests/test_codex_runtime.sh"
bash "${REPO_DIR}/tests/test_hook_health.sh"

echo
echo "Codex contract checks passed."

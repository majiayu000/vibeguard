#!/usr/bin/env bash
# Validate templates/AGENTS.md and every agents/*.md against
# schemas/prompt-contract.schema.json.
#
# Usage:
#   bash scripts/ci/validate-prompt-contract.sh           # warnings allowed
#   bash scripts/ci/validate-prompt-contract.sh --strict  # warnings -> errors

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="${REPO_DIR}/scripts/lib/vibeguard_manifest.py"

STRICT_FLAG=()
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT_FLAG=(--strict) ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

FAIL=0

run_one() {
  local target="$1"
  if ! python3 "$HELPER" validate-prompt-contract --target "$target" "${STRICT_FLAG[@]}"; then
    FAIL=$((FAIL + 1))
  fi
}

run_one "${REPO_DIR}/templates/AGENTS.md"

if [[ -d "${REPO_DIR}/agents" ]]; then
  while IFS= read -r -d '' role; do
    run_one "$role"
  done < <(find "${REPO_DIR}/agents" -maxdepth 1 -type f -name '*.md' -print0)
fi

exit $((FAIL > 0 ? 1 : 0))

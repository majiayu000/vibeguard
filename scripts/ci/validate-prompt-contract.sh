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

STRICT=0
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

FAIL=0

run_one() {
  local target="$1"
  local -a args=(validate-prompt-contract --target "$target")
  if [[ "${STRICT}" -eq 1 ]]; then
    args+=(--strict)
  fi
  if ! python3 "$HELPER" "${args[@]}"; then
    FAIL=$((FAIL + 1))
  fi
}

run_one "${REPO_DIR}/templates/AGENTS.md"

if [[ -d "${REPO_DIR}/agents" ]]; then
  for role in "${REPO_DIR}/agents"/*.md; do
    [[ -f "${role}" ]] || continue
    run_one "$role"
  done
fi

exit $((FAIL > 0 ? 1 : 0))

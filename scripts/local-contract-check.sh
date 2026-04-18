#!/usr/bin/env bash
# Run the stable, fast subset of contract checks locally.
# Mirrors the CI gate but excludes slow/environment-sensitive checks.
#
# Usage:
#   bash scripts/local-contract-check.sh           # full local gate
#   bash scripts/local-contract-check.sh --quick   # skip doc-freshness check

set -euo pipefail

REPO_DIR="$(git rev-parse --show-toplevel)"
QUICK=0
FAIL=0
declare -a FAILED_LABELS=()

# ---- flag parsing ----------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --quick) QUICK=1 ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# ---- helpers ---------------------------------------------------------------
is_unix() {
  local os
  os="$(uname -s 2>/dev/null || true)"
  [[ "$os" == "Linux" || "$os" == "Darwin" ]]
}

run_check() {
  local label="$1"
  local script="$2"
  local unix_only="${3:-false}"
  shift 3
  # remaining positional args are forwarded to the script

  if [[ "$unix_only" == "true" ]] && ! is_unix; then
    echo "  SKIP (non-Unix): $label"
    return
  fi

  if [[ ! -f "$script" ]]; then
    echo "  SKIP (not found): $label"
    return
  fi

  echo "  RUN: $label"
  if bash "$script" "$@"; then
    echo "  PASS: $label"
  else
    echo "  FAIL: $label"
    FAIL=$((FAIL + 1))
    FAILED_LABELS+=("$label")
  fi
}

# ---- checks ----------------------------------------------------------------
echo ""
echo "=== Local Contract Gate ==="
echo ""

run_check "validate-guards"          "$REPO_DIR/scripts/ci/validate-guards.sh"          "true"
run_check "validate-hooks"           "$REPO_DIR/scripts/ci/validate-hooks.sh"           "true"
run_check "validate-rules"           "$REPO_DIR/scripts/ci/validate-rules.sh"           "true"
run_check "validate-doc-paths"       "$REPO_DIR/scripts/ci/validate-doc-paths.sh"       "false"
run_check "validate-doc-command-paths" "$REPO_DIR/scripts/ci/validate-doc-command-paths.sh" "false"

if [[ "$QUICK" -eq 0 ]]; then
  run_check "doc-freshness (--strict)" "$REPO_DIR/scripts/verify/doc-freshness-check.sh" "true" --strict
else
  echo "  SKIP (--quick): doc-freshness"
fi

# PR #80 contract tests — activate automatically once those files exist
if [[ -f "$REPO_DIR/tests/test_manifest_contract.sh" ]]; then
  run_check "test_manifest_contract" "$REPO_DIR/tests/test_manifest_contract.sh" "true"
fi

if [[ -f "$REPO_DIR/tests/test_eval_contract.sh" ]]; then
  run_check "test_eval_contract"     "$REPO_DIR/tests/test_eval_contract.sh"     "true"
fi

# ---- summary ---------------------------------------------------------------
echo ""
echo "==========================="
if [[ "$FAIL" -eq 0 ]]; then
  echo "All checks passed."
else
  echo "FAILED checks (${FAIL}):"
  for lbl in "${FAILED_LABELS[@]}"; do
    echo "  - $lbl"
  done
  echo ""
  echo "To reproduce: bash scripts/local-contract-check.sh"
fi
echo "==========================="
echo ""

exit $((FAIL > 0 ? 1 : 0))

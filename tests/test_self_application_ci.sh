#!/usr/bin/env bash
# VibeGuard self-application CI regression tests
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SELF_DIR="${REPO_DIR}/scripts/ci/self-application"

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header(){ printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

assert_cmd() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (exit code: $?)"
    FAIL=$((FAIL + 1))
  fi
}

assert_fails() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    red "$desc (expected failure)"
    FAIL=$((FAIL + 1))
  else
    green "$desc"
    PASS=$((PASS + 1))
  fi
}

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

header "self-application scripts"
assert_cmd "all self-application scripts have valid syntax" bash -n "${SELF_DIR}"/*.sh
assert_cmd "self-application run-all passes on this repository" bash "${SELF_DIR}/run-all.sh" "${REPO_DIR}"
assert_cmd "U-22 measured coverage contract tests pass" bash "${REPO_DIR}/tests/test_u22_coverage.sh"
assert_cmd "test file size guard passes on this repository" bash "${REPO_DIR}/scripts/verify/check-test-file-sizes.sh"

source "${REPO_DIR}/tests/self_application/codex_wrapper_tests.sh"
source "${REPO_DIR}/tests/self_application/package_correction_tests.sh"
source "${REPO_DIR}/tests/self_application/policy_sentinel_tests.sh"
source "${REPO_DIR}/tests/self_application/sec14_mcp_tests.sh"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

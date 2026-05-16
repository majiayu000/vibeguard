#!/usr/bin/env bash
# Regression tests for read-only doctor entry points.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CODEX_DOCTOR="${REPO_DIR}/scripts/doctors/codex-doctor.sh"

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header(){ printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

assert_contains() {
  local output="$1" expected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$output" | grep -qF -- "$expected"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected to contain: $expected)"
    FAIL=$((FAIL + 1))
  fi
}

assert_cmd() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc"
    FAIL=$((FAIL + 1))
  fi
}

ORIG_HOME="${HOME}"
TMP_HOME="$(mktemp -d)"

cleanup() {
  export HOME="${ORIG_HOME}"
  rm -rf "${TMP_HOME}"
}
trap cleanup EXIT

export HOME="${TMP_HOME}"

header "codex-doctor is a read-only reporting wrapper"
doctor_out="$(bash "${CODEX_DOCTOR}" 2>&1)"

assert_contains "${doctor_out}" "VibeGuard Codex Doctor" "doctor has a clear title"
assert_contains "${doctor_out}" "Mode: read-only diagnostics" "doctor declares read-only mode"
assert_contains "${doctor_out}" "VibeGuard Codex Status" "doctor reuses Codex status report"
assert_contains "${doctor_out}" "Defense boundary" "doctor explains enforcement boundary"
assert_contains "${doctor_out}" "Doctor role: summarize installation" "doctor keeps diagnosis separate from enforcement"
assert_contains "${doctor_out}" "Guard role: block or warn during real tool execution" "doctor keeps guards as enforcement layer"
assert_cmd "codex-doctor is executable" test -x "${CODEX_DOCTOR}"
assert_cmd "codex-doctor does not create Codex config while diagnosing" test ! -e "${HOME}/.codex/config.toml"
assert_cmd "codex-doctor does not create Codex hooks while diagnosing" test ! -e "${HOME}/.codex/hooks.json"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

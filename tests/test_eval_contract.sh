#!/usr/bin/env bash
# VibeGuard eval contract regression tests
#
# Usage: bash tests/test_eval_contract.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR_RESOLVED="$(python3 - <<'PY' "${REPO_DIR}"
from pathlib import Path
import sys
print(Path(sys.argv[1]).resolve())
PY
)"

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

assert_contains() {
  local output="$1" expected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$output" | grep -qF "$expected"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected to contain: $expected)"
    FAIL=$((FAIL + 1))
  fi
}

header "eval runner syntax"
assert_cmd "eval/run_eval.py syntax is correct" python3 -m py_compile "${REPO_DIR}/eval/run_eval.py"

header "dry-run uses repository snapshot by default"
dry_run_out="$(cd "${REPO_DIR}" && python3 eval/run_eval.py --dry-run)"
assert_contains "${dry_run_out}" "Rules source: ${REPO_DIR_RESOLVED}/rules/claude-rules" "dry-run reports repository rule source"
assert_contains "${dry_run_out}" "Core constraint source: ${REPO_DIR_RESOLVED}/claude-md/vibeguard-rules.md" "dry-run reports repository core rules source"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

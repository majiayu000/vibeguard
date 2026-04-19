#!/usr/bin/env bash
# VibeGuard Unit Test Runner
#
# Runs all unit tests in tests/unit/ and reports aggregate results.
#
# Usage:
#   bash tests/unit/run_all.sh          # run all unit tests
#   bash tests/unit/run_all.sh --fast   # skip tests requiring optional deps (rg, python3)
#
# Exit code: 0 if all tests pass, 1 if any test fails.

set -euo pipefail

UNIT_DIR="$(cd "$(dirname "$0")" && pwd)"

PASS=0; FAIL=0; TOTAL=0

bold()  { printf '\033[1m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$1"; }

strip_ansi() {
  sed $'s/\x1B\\[[0-9;]*[A-Za-z]//g'
}

FAST_MODE=false
for arg in "$@"; do
  [[ "$arg" == "--fast" ]] && FAST_MODE=true
done

bold "=============================="
bold " VibeGuard Unit Tests"
bold "=============================="
echo

# Collect all test files sorted alphabetically
TESTS=()
while IFS= read -r -d '' f; do
  TESTS+=("$f")
done < <(find "$UNIT_DIR" -maxdepth 1 -name 'test_*.sh' -print0 | sort -z)

if [[ ${#TESTS[@]} -eq 0 ]]; then
  yellow "No unit test files found in ${UNIT_DIR}"
  exit 0
fi

FAILED_TESTS=()

for test_file in "${TESTS[@]}"; do
  test_name="$(basename "$test_file")"

  printf '%-55s ' "$test_name"

  # Capture output and exit code
  set +e
  output=$(bash "$test_file" 2>&1)
  exit_code=$?
  set -e

  TOTAL=$((TOTAL + 1))

  if [[ $exit_code -eq 0 ]]; then
    # Parse pass/fail counts from test output (last line: "Total: N  Pass: N  Fail: N")
    clean_output="$(printf '%s\n' "$output" | strip_ansi)"
    pass_count=$(echo "$clean_output" | grep -oE 'Pass:[[:space:]]*[0-9]+' | grep -oE '[0-9]+') || pass_count=""
    fail_count=$(echo "$clean_output" | grep -oE 'Fail:[[:space:]]*[0-9]+' | grep -oE '[0-9]+') || fail_count=""
    skip_count=$(echo "$clean_output" | grep -oE 'Skip:[[:space:]]*[0-9]+' | grep -oE '[0-9]+') || skip_count=""
    [[ -z "$pass_count" ]] && pass_count="N/A"
    [[ -z "$fail_count" ]] && fail_count="N/A"
    [[ -z "$skip_count" ]] && skip_count="0"
    if [[ "$pass_count" == "N/A" || "$fail_count" == "N/A" ]]; then
      yellow "WARN: could not parse assertion summary for ${test_name}"
    fi
    green "PASS (assertions: pass=${pass_count} fail=${fail_count} skip=${skip_count})"
    PASS=$((PASS + 1))
  else
    red "FAIL"
    FAILED_TESTS+=("$test_name")
    FAIL=$((FAIL + 1))
    # Show abbreviated output for failures
    echo "  --- Output ---"
    echo "$output" | grep -E '(FAIL|Error|error)' | head -10 | sed 's/^/  /'
    echo "  --- End ---"
  fi
done

echo
bold "=============================="
printf 'Total tests: %d\n' "$TOTAL"
printf 'Passed:      '; green "$PASS"
if [[ $FAIL -gt 0 ]]; then
  printf 'Failed:      '; red "$FAIL"
  echo
  red "FAILED TEST FILES:"
  for t in "${FAILED_TESTS[@]}"; do
    red "  - $t"
  done
  echo
  exit 1
else
  printf 'Failed:      %d\n' "$FAIL"
  echo
  green "All unit tests passed!"
fi
bold "=============================="

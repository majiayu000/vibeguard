#!/usr/bin/env bash

TEST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${VIBEGUARD_REPO_DIR:-$(cd "${TEST_LIB_DIR}/../.." && pwd)}"
cd "$REPO_DIR"

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header(){ printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

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

assert_not_contains() {
  local output="$1" unexpected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if ! echo "$output" | grep -qF "$unexpected"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (unexpectedly contains: $unexpected)"
    FAIL=$((FAIL + 1))
  fi
}

assert_occurrences() {
  local output="$1" needle="$2" expected_count="$3" desc="$4"
  local actual_count
  TOTAL=$((TOTAL + 1))
  actual_count=$(python3 -c '
import sys

haystack = sys.argv[1]
needle = sys.argv[2]
print(haystack.count(needle))
' "$output" "$needle")
  if [[ "$actual_count" == "$expected_count" ]]; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected $expected_count occurrences of: $needle, got $actual_count)"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit_zero() {
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

assert_exit_nonzero() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    red "$desc (unexpected success)"
    FAIL=$((FAIL + 1))
  else
    green "$desc"
    PASS=$((PASS + 1))
  fi
}

hook_test_init() {
  export VIBEGUARD_LOG_DIR="${VIBEGUARD_LOG_DIR:-$(mktemp -d)}"
  trap 'rm -rf "$VIBEGUARD_LOG_DIR"' EXIT
}

hook_test_finish() {
  echo
  echo "=============================="
  printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
  echo "=============================="

  if [[ $FAIL -gt 0 ]]; then
    exit 1
  fi
}

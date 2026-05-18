#!/usr/bin/env bash
# Regression tests for the hook latency/performance contract.
#
# Usage: bash tests/test_hook_perf_contract.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATOR="${REPO_DIR}/scripts/ci/validate-hook-perf.sh"
BENCH="${REPO_DIR}/tests/bench_hook_latency.sh"

PASS=0
FAIL=0
TOTAL=0
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

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
    red "$desc"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_contains() {
  local file="$1"
  local expected="$2"
  local desc="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qF -- "$expected" "$file"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected: $expected)"
    FAIL=$((FAIL + 1))
  fi
}

assert_fail_contains() {
  local desc="$1"
  local expected="$2"
  local output_file="$3"
  shift 3
  TOTAL=$((TOTAL + 1))
  "$@" >"${output_file}" 2>&1
  local exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qF -- "$expected" "${output_file}"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (exit=${exit_code}, expected output: $expected)"
    FAIL=$((FAIL + 1))
  fi
}

write_hook() {
  local dir="$1"
  local name="$2"
  local body="$3"
  mkdir -p "$dir"
  printf '%s\n' '#!/usr/bin/env bash' "$body" > "${dir}/${name}"
  chmod +x "${dir}/${name}"
}

header "syntax"
assert_cmd "performance validator syntax" bash -n "${VALIDATOR}"
assert_cmd "latency benchmark syntax" bash -n "${BENCH}"

header "static performance gates"
GOOD_HOOKS="${TMP_DIR}/good-hooks"
write_hook "${GOOD_HOOKS}" "good-hook.sh" 'find "$PROJECT_DIR" -maxdepth 1 -type f >/dev/null 2>&1 || true'
assert_cmd "bounded find passes static validator" env VIBEGUARD_HOOKS_DIR="${GOOD_HOOKS}" bash "${VALIDATOR}"

DOCUMENTED_HOOKS="${TMP_DIR}/documented-hooks"
write_hook "${DOCUMENTED_HOOKS}" "documented-hook.sh" '# PERF-OK: fixture intentionally scans its temp project root.
find "$PROJECT_DIR" -type f >/dev/null 2>&1 || true'
assert_cmd "PERF-OK documents an intentional scan" env VIBEGUARD_HOOKS_DIR="${DOCUMENTED_HOOKS}" bash "${VALIDATOR}"

BAD_FIND_HOOKS="${TMP_DIR}/bad-find-hooks"
write_hook "${BAD_FIND_HOOKS}" "bad-find-hook.sh" 'find "$PROJECT_DIR" -type f >/dev/null 2>&1 || true'
assert_fail_contains "unbounded find fails static validator" "PERF-02" "${TMP_DIR}/bad-find.out" env VIBEGUARD_HOOKS_DIR="${BAD_FIND_HOOKS}" bash "${VALIDATOR}"
assert_file_contains "${TMP_DIR}/bad-find.out" "bad-find-hook.sh" "unbounded find output names the hook"

BAD_LOOP_HOOKS="${TMP_DIR}/bad-loop-hooks"
write_hook "${BAD_LOOP_HOOKS}" "bad-loop-hook.sh" 'while read -r path; do python3 -c "print(1)" "$path"; done < /dev/null'
assert_fail_contains "subprocess in loop fails static validator" "PERF-04" "${TMP_DIR}/bad-loop.out" env VIBEGUARD_HOOKS_DIR="${BAD_LOOP_HOOKS}" bash "${VALIDATOR}"
assert_file_contains "${TMP_DIR}/bad-loop.out" "bad-loop-hook.sh" "loop subprocess output names the hook"

header "dynamic latency gate"
assert_fail_contains "synthetic slow hook fails latency budget" "synthetic-slow-hook" "${TMP_DIR}/slow.out" bash "${BENCH}" --runs=1 --include-slow-fixture --fail-on-regression
assert_file_contains "${TMP_DIR}/slow.out" "exceeded latency budget" "slow hook output explains budget failure"
assert_file_contains "${TMP_DIR}/slow.out" "hotspot=synthetic sleep fixture" "slow hook output includes hotspot attribution"
assert_file_contains "${REPO_DIR}/bench-output.json" "(P50)" "benchmark action output includes P50 samples"
assert_file_contains "${REPO_DIR}/bench-output.json" "(P95)" "benchmark action output includes P95 samples"
assert_file_contains "${REPO_DIR}/bench-output.json" "(P99)" "benchmark action output includes P99 samples"

echo ""
echo "======================================"
echo "Hook performance contract tests: ${PASS}/${TOTAL} passed"
echo "======================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi

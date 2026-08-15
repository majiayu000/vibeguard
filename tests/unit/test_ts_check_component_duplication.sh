#!/usr/bin/env bash
# Unit tests for guards/typescript/check_component_duplication.sh (TS-13)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="${REPO_DIR}/guards/typescript/check_component_duplication.sh"

PASS=0; FAIL=0; TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }

assert_fail() {
  local desc="$1"; shift; TOTAL=$((TOTAL+1))
  if "$@" >/dev/null 2>&1; then red "$desc (expected non-zero)"; FAIL=$((FAIL+1))
  else green "$desc"; PASS=$((PASS+1)); fi
}

assert_output_contains() {
  local desc="$1" expected="$2"; shift 2; TOTAL=$((TOTAL+1))
  local out; out=$("$@" 2>&1 || true)
  if echo "$out" | grep -qF "$expected"; then green "$desc"; PASS=$((PASS+1))
  else red "$desc (missing: $expected)"; FAIL=$((FAIL+1)); fi
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

printf '\n=== check_component_duplication (TS-13) ===\n'

# --- FAIL: capitalized Hooks/ directories remain part of query-hook detection ---
proj_hooks="${tmpdir}/fail_capitalized_hooks"
mkdir -p "${proj_hooks}/src/Hooks"
for name in account profile team project; do
  file="${proj_hooks}/src/Hooks/${name}.ts"
  printf '%s\n' \
    'export function queryTemplate() {' \
    '  const result = useQuery({ queryKey: ["item"] });' \
    '  const { data, isLoading, error, refetch } = result;' \
    '  return { data, isLoading, error, refetch };' \
    '}' > "$file"
done
assert_fail "capitalized Hooks directory query templates fail --strict" \
  bash "$GUARD" --strict "$proj_hooks"
assert_output_contains "output names query hook duplication" "Query hook template pattern" \
  bash "$GUARD" --strict "$proj_hooks"

echo
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' "$TOTAL" "$PASS" "$FAIL"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0

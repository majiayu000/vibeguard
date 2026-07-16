#!/usr/bin/env bash
# Unit tests for scripts/verify/compliance_check.sh bundled guard discovery.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CHECKER="${REPO_DIR}/scripts/verify/compliance_check.sh"

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red() { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }

assert_eq() {
  local desc="$1"
  local expected="$2"
  local actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "${actual}" == "${expected}" ]]; then
    green "${desc}"
    PASS=$((PASS + 1))
  else
    red "${desc} (expected ${expected}, got ${actual})"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1"
  local output="$2"
  local expected="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qF "${expected}" <<< "${output}"; then
    green "${desc}"
    PASS=$((PASS + 1))
  else
    red "${desc} (missing: ${expected})"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1"
  local output="$2"
  local unexpected="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qF "${unexpected}" <<< "${output}"; then
    red "${desc} (unexpected: ${unexpected})"
    FAIL=$((FAIL + 1))
  else
    green "${desc}"
    PASS=$((PASS + 1))
  fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

PROJECT_DIR="${TMP_DIR}/project"
FIXTURE_HOME="${TMP_DIR}/home"
OUTSIDE_CWD="${TMP_DIR}/outside cwd"
OVERRIDE_ROOT="${TMP_DIR}/explicit root"

mkdir -p \
  "${PROJECT_DIR}" \
  "${FIXTURE_HOME}/.claude/skills/vibeguard" \
  "${FIXTURE_HOME}/.claude/rules/vibeguard" \
  "${OUTSIDE_CWD}" \
  "${OVERRIDE_ROOT}/guards/python"

printf '%s\n' \
  'repos:' \
  '  - repo: local' \
  '    hooks:' \
  '      - id: gitleaks' \
  '      - id: ruff' \
  > "${PROJECT_DIR}/.pre-commit-config.yaml"
printf '%s\n' \
  'Search before writing.' \
  'No backward compatibility.' \
  'No hardcoding.' \
  > "${PROJECT_DIR}/CLAUDE.md"
printf '%s\n' 'VibeGuard anti-hallucination rules.' > "${FIXTURE_HOME}/.claude/CLAUDE.md"
printf '%s\n' '# duplicate fixture' > "${OVERRIDE_ROOT}/guards/python/check_duplicates.py"
printf '%s\n' '# naming fixture' > "${OVERRIDE_ROOT}/guards/python/check_naming_convention.py"

printf '\n=== compliance_check bundled guard discovery ===\n'

set +e
default_output="$({
  cd "${OUTSIDE_CWD}" || exit 97
  unset VIBEGUARD_DIR
  HOME="${FIXTURE_HOME}" bash "${CHECKER}" "${PROJECT_DIR}"
} 2>&1)"
default_status=$?
set -e

assert_eq "default invocation preserves compliance exit contract" 0 "${default_status}"
assert_contains \
  "default invocation finds bundled duplicate guard from external cwd" \
  "${default_output}" \
  "check_duplicates.py available (${REPO_DIR}/guards/python/check_duplicates.py)"
assert_contains \
  "default invocation finds bundled naming guard from external cwd" \
  "${default_output}" \
  "check_naming_convention.py available (${REPO_DIR}/guards/python/check_naming_convention.py)"
assert_not_contains \
  "default invocation does not emit duplicate guard not-found warning" \
  "${default_output}" \
  "check_duplicates.py not found"
assert_not_contains \
  "default invocation does not emit naming guard not-found warning" \
  "${default_output}" \
  "check_naming_convention.py not found"

set +e
override_output="$({
  cd "${OUTSIDE_CWD}" || exit 97
  HOME="${FIXTURE_HOME}" VIBEGUARD_DIR="${OVERRIDE_ROOT}" \
    bash "${CHECKER}" "${PROJECT_DIR}"
} 2>&1)"
override_status=$?
set -e

assert_eq "explicit root preserves compliance exit contract" 0 "${override_status}"
assert_contains \
  "explicit root with spaces wins for duplicate guard" \
  "${override_output}" \
  "check_duplicates.py available (${OVERRIDE_ROOT}/guards/python/check_duplicates.py)"
assert_contains \
  "explicit root with spaces wins for naming guard" \
  "${override_output}" \
  "check_naming_convention.py available (${OVERRIDE_ROOT}/guards/python/check_naming_convention.py)"
assert_not_contains \
  "explicit root does not fall back to repository duplicate guard" \
  "${override_output}" \
  "check_duplicates.py available (${REPO_DIR}/guards/python/check_duplicates.py)"
assert_not_contains \
  "explicit root does not fall back to repository naming guard" \
  "${override_output}" \
  "check_naming_convention.py available (${REPO_DIR}/guards/python/check_naming_convention.py)"

echo
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' \
  "${TOTAL}" "${PASS}" "${FAIL}"
[[ "${FAIL}" -gt 0 ]] && exit 1 || exit 0

#!/usr/bin/env bash
# Unit tests for guards/universal/check_runtime_drift.sh (W-20).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="${REPO_DIR}/guards/universal/check_runtime_drift.sh"

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red() { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }

run_expect() {
  local desc="$1"
  local expected="$2"
  local pattern="$3"
  shift 3

  TOTAL=$((TOTAL + 1))
  local out rc
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e

  if [[ "${rc}" -ne "${expected}" ]]; then
    red "${desc} (expected exit ${expected}, got ${rc})"
    printf '%s\n' "${out}" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
    return
  fi
  if [[ -n "${pattern}" ]] && ! grep -qF "${pattern}" <<< "${out}"; then
    red "${desc} (missing: ${pattern})"
    printf '%s\n' "${out}" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
    return
  fi
  green "${desc}"
  PASS=$((PASS + 1))
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

RUNTIME_FILE="${TMP_DIR}/runtime.txt"
TOOLS_FILE="${TMP_DIR}/tools.txt"
RULES_DIR="${TMP_DIR}/rules"
SNAPSHOT="${TMP_DIR}/runtime-pinning.snapshot"
DECISION_LOG="${TMP_DIR}/SECURITY.md"

mkdir -p "${RULES_DIR}/common"
printf 'codex=codex 1.0.0\nmodel_id=gpt-test\n' > "${RUNTIME_FILE}"
printf 'mcp github.get_pull_request %064d\n' 1 > "${TOOLS_FILE}"
printf '## W-20: Long tasks must pin runtime, tools, and rules (strict)\n' > "${RULES_DIR}/common/execution-pinning.md"

printf '\n=== check_runtime_drift (W-20) ===\n'

run_expect "snapshot writes baseline" 0 "snapshot written" \
  bash "${GUARD}" snapshot \
    --snapshot "${SNAPSHOT}" \
    --tool-inventory "${TOOLS_FILE}" \
    --runtime-inventory "${RUNTIME_FILE}" \
    --rules-dir "${RULES_DIR}"

run_expect "unchanged runtime tools and rules pass" 0 "OK" \
  bash "${GUARD}" check \
    --snapshot "${SNAPSHOT}" \
    --tool-inventory "${TOOLS_FILE}" \
    --runtime-inventory "${RUNTIME_FILE}" \
    --rules-dir "${RULES_DIR}"

printf 'skill vibeguard %064d\n' 2 >> "${TOOLS_FILE}"
run_expect "tool inventory drift fails" 1 "tools drift" \
  bash "${GUARD}" check \
    --snapshot "${SNAPSHOT}" \
    --tool-inventory "${TOOLS_FILE}" \
    --runtime-inventory "${RUNTIME_FILE}" \
    --rules-dir "${RULES_DIR}"

run_expect "accept records drift decision" 0 "drift acceptance recorded" \
  bash "${GUARD}" accept \
    --snapshot "${SNAPSHOT}" \
    --tool-inventory "${TOOLS_FILE}" \
    --runtime-inventory "${RUNTIME_FILE}" \
    --rules-dir "${RULES_DIR}" \
    --decision-log "${DECISION_LOG}" \
    --reason "User accepted tool inventory change for test"

if grep -qF "User accepted tool inventory change for test" "${DECISION_LOG}"; then
  green "acceptance log includes reason"
  PASS=$((PASS + 1))
else
  red "acceptance log includes reason"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

printf 'mcp invalid not-a-sha\n' > "${TOOLS_FILE}"
run_expect "malformed tool inventory fails as usage error" 2 "invalid description hash" \
  bash "${GUARD}" check \
    --snapshot "${SNAPSHOT}" \
    --tool-inventory "${TOOLS_FILE}" \
    --runtime-inventory "${RUNTIME_FILE}" \
    --rules-dir "${RULES_DIR}"

printf 'mcp github.get_pull_request %064d\n' 1 > "${TOOLS_FILE}"
printf '\n## W-21: Changed rule\n' >> "${RULES_DIR}/common/execution-pinning.md"
run_expect "rules drift fails" 1 "rules drift" \
  bash "${GUARD}" check \
    --snapshot "${SNAPSHOT}" \
    --tool-inventory "${TOOLS_FILE}" \
    --runtime-inventory "${RUNTIME_FILE}" \
    --rules-dir "${RULES_DIR}"

echo
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' "${TOTAL}" "${PASS}" "${FAIL}"
[[ "${FAIL}" -gt 0 ]] && exit 1 || exit 0

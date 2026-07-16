#!/usr/bin/env bash
# Keep hook regression tests discoverable and below god-file limits.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
errors=0

check_file() {
  local path="$1" max_lines="$2"
  local lines
  lines=$(wc -l <"${path}" | tr -d ' ')
  if [[ "${lines}" -gt "${max_lines}" ]]; then
    echo "FAIL: ${path#${REPO_DIR}/} has ${lines} lines (max ${max_lines})"
    errors=$((errors + 1))
  else
    echo "OK: ${path#${REPO_DIR}/} has ${lines} lines"
  fi
}

check_file "${REPO_DIR}/tests/test_hooks.sh" 100
check_file "${REPO_DIR}/tests/test_self_application_ci.sh" 399

for file in "${REPO_DIR}"/tests/hooks/*.sh; do
  [[ -f "${file}" ]] || continue
  check_file "${file}" 400
done

for file in "${REPO_DIR}"/tests/self_application/*.sh; do
  [[ -f "${file}" ]] || continue
  check_file "${file}" 399
done

for file in "${REPO_DIR}"/vibeguard-runtime/tests/*.rs; do
  [[ -f "${file}" ]] || continue
  check_file "${file}" 800
done

if [[ "${errors}" -gt 0 ]]; then
  exit 1
fi

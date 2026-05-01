#!/usr/bin/env bash
# Ensure the Codex runtime wrapper stays thin and delegates JSON adaptation.
set -euo pipefail

REPO_DIR="${1:-$(cd "$(dirname "$0")/../../.." && pwd)}"
WRAPPER="${REPO_DIR}/hooks/run-hook-codex.sh"
ADAPTER="${REPO_DIR}/hooks/_lib/codex_adapter.sh"

errors=()

add_error() {
  errors+=("$1")
}

if [[ ! -f "${WRAPPER}" ]]; then
  add_error "missing hooks/run-hook-codex.sh"
fi

if [[ ! -f "${ADAPTER}" ]]; then
  add_error "missing hooks/_lib/codex_adapter.sh"
fi

if [[ -f "${WRAPPER}" ]]; then
  wrapper_lines=$(wc -l <"${WRAPPER}" | tr -d ' ')
  if [[ "${wrapper_lines}" -gt 140 ]]; then
    add_error "hooks/run-hook-codex.sh is ${wrapper_lines} lines; keep wrapper <= 140 lines"
  fi

  if grep -nE "(^|[^A-Za-z0-9_])python3([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_])python[[:space:]]+-|<<'?(PY|PYCODE)'?" "${WRAPPER}" >/dev/null; then
    add_error "hooks/run-hook-codex.sh contains inline Python/heredoc adapter logic"
  fi

  if ! grep -q '_lib/codex_adapter.sh' "${WRAPPER}"; then
    add_error "hooks/run-hook-codex.sh does not resolve hooks/_lib/codex_adapter.sh"
  fi

  if ! grep -q 'source "${ADAPTER_PATH}"' "${WRAPPER}"; then
    add_error "hooks/run-hook-codex.sh does not source the Codex adapter"
  fi

  for fn in codex_event_name codex_pretool_deny codex_adapt_pretool codex_adapt_posttool; do
    if ! grep -q "${fn}" "${WRAPPER}"; then
      add_error "hooks/run-hook-codex.sh does not delegate through ${fn}"
    fi
  done
fi

if [[ -f "${ADAPTER}" ]]; then
  for fn in codex_event_name codex_pretool_deny codex_adapt_pretool codex_adapt_posttool; do
    if ! grep -q "^${fn}()" "${ADAPTER}"; then
      add_error "hooks/_lib/codex_adapter.sh does not define ${fn}"
    fi
  done
fi

if [[ "${#errors[@]}" -gt 0 ]]; then
  printf 'FAIL: Codex wrapper thinness check found %d issue(s):\n' "${#errors[@]}" >&2
  for error in "${errors[@]}"; do
    printf '  - %s\n' "${error}" >&2
  done
  exit 1
fi

echo "OK: Codex wrapper delegates adapter logic to hooks/_lib/codex_adapter.sh"

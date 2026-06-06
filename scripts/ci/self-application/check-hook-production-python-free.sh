#!/usr/bin/env bash
# #383 self-application: configured first-party hook runtime paths stay Python-free.
set -euo pipefail

REPO_DIR="${1:-$(cd "$(dirname "$0")/../../.." && pwd)}"

errors=()

add_error() {
  errors+=("$1")
}

scan_file() {
  local rel="$1" path="${REPO_DIR}/${rel}"
  [[ -f "${path}" ]] || { add_error "missing ${rel}"; return 0; }
  if grep -nE "(^|[^A-Za-z0-9_])python3([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_])python[[:space:]]+-|<<'?(PY|PYCODE)'?" "${path}" >/dev/null; then
    add_error "${rel} contains Python execution in the configured hook production path"
  fi
}

configured_paths=(
  "hooks/run-hook.sh"
  "hooks/run-hook-codex.sh"
  "hooks/log.sh"
  "hooks/pre-bash-guard.sh"
  "hooks/pre-edit-guard.sh"
  "hooks/pre-write-guard.sh"
  "hooks/post-edit-guard.sh"
  "hooks/post-write-guard.sh"
  "hooks/analysis-paralysis-guard.sh"
  "hooks/count_active_constraints.sh"
  "hooks/stop-guard.sh"
  "hooks/learn-evaluator.sh"
  "hooks/post-build-check.sh"
)

for rel in "${configured_paths[@]}"; do
  scan_file "${rel}"
done

for helper in "${REPO_DIR}"/hooks/_lib/*.sh; do
  [[ -f "${helper}" ]] || continue
  scan_file "${helper#${REPO_DIR}/}"
done

for rel in \
  "hooks/run-hook.sh" \
  "hooks/run-hook-codex.sh" \
  "hooks/_lib/policy.sh" \
  "hooks/_lib/codex_runner.sh"; do
  path="${REPO_DIR}/${rel}"
  [[ -f "${path}" ]] || continue
  if grep -qE "policy\\.py|codex_apply_patch_adapter\\.py" "${path}"; then
    add_error "${rel} still references a removed Python production fallback helper"
  fi
done

if [[ "${#errors[@]}" -gt 0 ]]; then
  printf 'FAIL: configured hook production path Python-free check found %d issue(s):\n' "${#errors[@]}" >&2
  for error in "${errors[@]}"; do
    printf '  - %s\n' "${error}" >&2
  done
  exit 1
fi

echo "OK: configured hook production path is Python-free"

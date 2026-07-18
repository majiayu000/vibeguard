#!/usr/bin/env bash
# VibeGuard Session Metrics + Correction Detection — Stop event metric collection
#
# Thin compatibility entry point. The hot path lives in vibeguard-runtime so
# learning Stop hooks avoid sourcing the shared bash logging stack.

set -euo pipefail

_VG_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_VIBEGUARD_RUNTIME=""

_vg_learn_installed_context() {
  local installed_hooks="${HOME:-}/.vibeguard/installed/hooks"
  [[ -n "${HOME:-}" && ( "${_VG_HOOK_DIR}" == "${installed_hooks}" || "${_VG_HOOK_DIR}" == "${installed_hooks}/"* ) ]]
}

_vg_learn_runtime_candidates() {
  printf '%s\n' "${VIBEGUARD_RUNTIME:-}"
  if _vg_learn_installed_context; then
    printf '%s\n' "${HOME}/.vibeguard/installed/bin/vibeguard-runtime"
    printf '%s\n' "${_VG_HOOK_DIR}/vibeguard-runtime"
    printf '%s\n' "${_VG_HOOK_DIR}/../vibeguard-runtime/target/release/vibeguard-runtime"
    printf '%s\n' "${_VG_HOOK_DIR}/../vibeguard-runtime/target/debug/vibeguard-runtime"
  else
    printf '%s\n' "${_VG_HOOK_DIR}/../vibeguard-runtime/target/release/vibeguard-runtime"
    printf '%s\n' "${_VG_HOOK_DIR}/../vibeguard-runtime/target/debug/vibeguard-runtime"
    printf '%s\n' "${HOME:-}/.vibeguard/installed/bin/vibeguard-runtime"
    printf '%s\n' "${_VG_HOOK_DIR}/vibeguard-runtime"
  fi
}

while IFS= read -r _candidate; do
  if [[ -n "$_candidate" && -f "$_candidate" && -x "$_candidate" ]]; then
    _VIBEGUARD_RUNTIME="$_candidate"
    break
  fi
done < <(_vg_learn_runtime_candidates)

if [[ -z "$_VIBEGUARD_RUNTIME" ]]; then
  printf '%s\n' "VIBEGUARD ERROR: vibeguard-runtime not found. Run setup.sh or cargo build --release --manifest-path vibeguard-runtime/Cargo.toml." >&2
  exit 2
fi

exec "$_VIBEGUARD_RUNTIME" hook learn

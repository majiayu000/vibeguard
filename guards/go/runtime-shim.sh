#!/usr/bin/env bash

set -euo pipefail

run_runtime_guard() {
  local language="$1" rule="$2"
  shift 2
  local script_dir repo_dir candidate
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_dir="$(cd "${script_dir}/../.." && pwd)"
  if [[ -n "${VIBEGUARD_RUNTIME:-}" ]]; then
    candidate="${VIBEGUARD_RUNTIME}"
    if [[ "${candidate}" != */* ]]; then
      candidate="$(command -v "${candidate}" 2>/dev/null || true)"
    fi
    if [[ -z "${candidate}" || ! -f "${candidate}" || ! -x "${candidate}" ]]; then
      printf 'VIBEGUARD_RUNTIME is not executable or not found: %s\n' "${VIBEGUARD_RUNTIME}" >&2
      exit 2
    fi
    exec "${candidate}" scan "${language}" "${rule}" "$@"
  fi
  runtime_supports_scan() {
    local usage
    usage="$("$1" 2>&1 || true)"
    grep -qE '^  scan[[:space:]]' <<< "${usage}"
  }
  for candidate in \
    "${repo_dir}/vibeguard-runtime/target/release/vibeguard-runtime" \
    "${repo_dir}/vibeguard-runtime/target/debug/vibeguard-runtime" \
    "${HOME:-}/.vibeguard/installed/bin/vibeguard-runtime"; do
    if [[ -n "${candidate}" && -f "${candidate}" && -x "${candidate}" ]] \
      && runtime_supports_scan "${candidate}"; then
      exec "${candidate}" scan "${language}" "${rule}" "$@"
    fi
  done
  printf '%s\n' "VIBEGUARD ERROR: vibeguard-runtime not found. Run setup.sh or cargo build --release --manifest-path vibeguard-runtime/Cargo.toml." >&2
  exit 2
}

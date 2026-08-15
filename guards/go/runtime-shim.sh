#!/usr/bin/env bash

set -euo pipefail

run_runtime_guard() {
  local language="$1" rule="$2"
  shift 2
  local script_dir repo_dir candidate
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_dir="$(cd "${script_dir}/../.." && pwd)"
  for candidate in \
    "${VIBEGUARD_RUNTIME:-}" \
    "${repo_dir}/vibeguard-runtime/target/debug/vibeguard-runtime" \
    "${repo_dir}/vibeguard-runtime/target/release/vibeguard-runtime" \
    "${HOME:-}/.vibeguard/installed/bin/vibeguard-runtime"; do
    if [[ -n "${candidate}" && -f "${candidate}" && -x "${candidate}" ]]; then
      exec "${candidate}" scan "${language}" "${rule}" "$@"
    fi
  done
  printf '%s\n' "VIBEGUARD ERROR: vibeguard-runtime not found. Run setup.sh or cargo build --release --manifest-path vibeguard-runtime/Cargo.toml." >&2
  exit 2
}

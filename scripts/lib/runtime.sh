#!/usr/bin/env bash

vg_resolve_runtime() {
  local repo_dir="${1:?vg_resolve_runtime requires repo dir}"
  local capability="${2:-observe_legacy}"

  local explicit_runtime="${VIBEGUARD_RUNTIME:-}"
  local candidates=()
  if [[ -n "${explicit_runtime}" ]]; then
    if ! resolved="$(vg_resolve_runtime_candidate "${explicit_runtime}")"; then
      printf 'VIBEGUARD_RUNTIME is not executable or not found: %s\n' "${explicit_runtime}" >&2
      return 2
    fi
    if ! vg_runtime_supports "${resolved}" "${capability}"; then
      printf 'VIBEGUARD_RUNTIME does not support required capability: %s\n' "${capability}" >&2
      return 2
    fi
    printf '%s\n' "${resolved}"
    return 0
  fi

  if [[ -n "${HOME:-}" ]]; then
    candidates+=("${HOME}/.vibeguard/installed/bin/vibeguard-runtime")
  fi
  candidates+=(
    "${repo_dir}/vibeguard-runtime/target/release/vibeguard-runtime"
    "${repo_dir}/vibeguard-runtime/target/debug/vibeguard-runtime"
    "vibeguard-runtime"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if resolved="$(vg_resolve_runtime_candidate "${candidate}")"; then
      if vg_runtime_supports "${resolved}" "${capability}"; then
        printf '%s\n' "${resolved}"
        return 0
      fi
    fi
  done

  printf '%s\n' "vibeguard-runtime not found. Run cargo build --manifest-path vibeguard-runtime/Cargo.toml or setup.sh." >&2
  return 2
}

vg_resolve_runtime_candidate() {
  local candidate="${1:-}" resolved
  [[ -n "${candidate}" ]] || return 1

  if [[ "${candidate}" == */* ]]; then
    if [[ -f "${candidate}" && -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
    return 1
  fi

  if resolved="$(command -v "${candidate}" 2>/dev/null)" && [[ -n "${resolved}" && -x "${resolved}" ]]; then
    printf '%s\n' "${resolved}"
    return 0
  fi

  return 1
}

vg_runtime_supports() {
  local candidate="$1"
  local capability="$2"
  case "${capability}" in
    observe_legacy)
      vg_runtime_supports_observe "${candidate}"
      ;;
    observe_export_prometheus)
      vg_runtime_supports_observe_export_prometheus "${candidate}"
      ;;
    *)
      return 2
      ;;
  esac
}

vg_runtime_supports_observe() {
  local candidate="$1"
  "${candidate}" observe summary --legacy --days all --limit all --log-file /dev/null >/dev/null 2>&1
}

vg_runtime_supports_observe_export_prometheus() {
  local candidate="$1"
  "${candidate}" observe export prometheus --since all --input-file /dev/null >/dev/null 2>&1
}

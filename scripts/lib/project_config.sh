#!/usr/bin/env bash
# Lightweight .vibeguard.json reader for shell scripts.

_VG_PROJECT_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_VG_PROJECT_CONFIG_ROOT="$(cd "${_VG_PROJECT_CONFIG_LIB_DIR}/../.." && pwd)"

_vg_project_config_runtime_path() {
  local candidate resolved
  for candidate in \
    "${VIBEGUARD_PROJECT_CONFIG_RUNTIME:-}" \
    "${VIBEGUARD_RUNTIME:-}" \
    "${_VG_PROJECT_CONFIG_ROOT}/vibeguard-runtime/target/release/vibeguard-runtime" \
    "${_VG_PROJECT_CONFIG_ROOT}/vibeguard-runtime/target/debug/vibeguard-runtime" \
    "${_VG_PROJECT_CONFIG_ROOT}/bin/vibeguard-runtime" \
    "${HOME}/.vibeguard/installed/bin/vibeguard-runtime"; do
    if resolved="$(_vg_project_config_resolve_runtime_candidate "${candidate}")"; then
      if _vg_project_config_runtime_supports "${resolved}"; then
        printf '%s\n' "${resolved}"
        return 0
      fi
    fi
  done

  if resolved="$(_vg_project_config_resolve_runtime_candidate "vibeguard-runtime")"; then
    if _vg_project_config_runtime_supports "${resolved}"; then
      printf '%s\n' "${resolved}"
      return 0
    fi
  fi

  return 1
}

_vg_project_config_resolve_runtime_candidate() {
  local candidate="${1:-}" resolved
  if [[ -z "${candidate}" ]]; then
    return 1
  fi

  if [[ -f "${candidate}" && -x "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  if [[ "${candidate}" != */* ]] && resolved="$(command -v "${candidate}" 2>/dev/null)"; then
    if [[ -n "${resolved}" && -x "${resolved}" ]]; then
      printf '%s\n' "${resolved}"
      return 0
    fi
  fi

  return 1
}

_vg_project_config_runtime_supports() {
  local candidate="$1" probe_file value_probe
  probe_file="${TMPDIR:-/tmp}/vibeguard-project-config-probe.$$.json"
  printf '{"gc":{"log_threshold_mb":19}}\n' > "${probe_file}" || return 1
  "${candidate}" project-config-validate "${probe_file}" >/dev/null 2>&1 || {
    rm -f "${probe_file}" 2>/dev/null || true
    return 1
  }
  value_probe="$("${candidate}" project-config-value "${probe_file}" gc.log_threshold_mb 17 2>/dev/null)" || {
    rm -f "${probe_file}" 2>/dev/null || true
    return 1
  }
  rm -f "${probe_file}" 2>/dev/null || true
  [[ "${value_probe}" == "19" ]]
}

vg_project_config_file() {
  if [[ -n "${VIBEGUARD_PROJECT_CONFIG:-}" ]]; then
    printf '%s\n' "${VIBEGUARD_PROJECT_CONFIG}"
    return 0
  fi

  local root=""
  root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [[ -n "$root" && -f "${root}/.vibeguard.json" ]]; then
    printf '%s\n' "${root}/.vibeguard.json"
    return 0
  fi

  if [[ -f ".vibeguard.json" ]]; then
    printf '%s\n' ".vibeguard.json"
  fi
}

vg_validate_project_config() {
  local config_file="${1:-}" runtime_path
  if [[ -z "$config_file" ]]; then
    config_file="$(vg_project_config_file)"
  fi

  if [[ -z "$config_file" || ! -f "$config_file" ]]; then
    return 0
  fi

  if ! runtime_path="$(_vg_project_config_runtime_path)"; then
    printf 'VibeGuard project config invalid: vibeguard-runtime with project-config-validate is required to validate %s\n' "$config_file" >&2
    return 1
  fi

  "${runtime_path}" project-config-validate "$config_file"
}

vg_config_value() {
  local key_path="$1"
  local default_value="${2:-}"
  local config_file runtime_path
  config_file="$(vg_project_config_file)"

  if [[ -z "$config_file" || ! -f "$config_file" ]]; then
    printf '%s\n' "$default_value"
    return 0
  fi

  if ! runtime_path="$(_vg_project_config_runtime_path)"; then
    printf 'VibeGuard project config read failed: vibeguard-runtime with project-config-value is required to read %s\n' "$config_file" >&2
    return 2
  fi

  "${runtime_path}" project-config-value "$config_file" "$key_path" "$default_value"
}

vg_config_positive_int() {
  local env_name="$1"
  local key_path="$2"
  local default_value="$3"
  local raw_value="${!env_name:-}"

  if [[ -z "$raw_value" ]]; then
    if ! raw_value="$(vg_config_value "$key_path" "$default_value")"; then
      return 2
    fi
  fi

  if [[ "$raw_value" =~ ^[0-9]+$ && "$raw_value" -gt 0 ]]; then
    printf '%s\n' "$raw_value"
  else
    printf '%s\n' "$default_value"
  fi
}

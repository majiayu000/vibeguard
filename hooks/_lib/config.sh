#!/usr/bin/env bash
# VibeGuard layered config reader.
#
# Resolution order:
#   1. Environment variable supplied by the caller.
#   2. JSON config file at $_VG_CONFIG_FILE / $VIBEGUARD_CONFIG_FILE, or
#      ${VIBEGUARD_LOG_DIR:-$HOME/.vibeguard}/config.json.
#   3. Caller-provided default.
#
# Every helper validates an existing config before applying env-over-JSON-default
# resolution. Invalid files fail visibly even when an environment override exists.

if [[ -n "${_VG_CONFIG_SH_LOADED:-}" ]]; then
  return 0
fi
_VG_CONFIG_SH_LOADED=1
_VG_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_vg_config_file() {
  printf '%s' "${_VG_CONFIG_FILE:-${VIBEGUARD_CONFIG_FILE:-${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}/config.json}}"
}

_vg_config_runtime_path() {
  local wrapper_dir candidate cache_key
  wrapper_dir="$(cd "${_VG_CONFIG_LIB_DIR}/.." && pwd)"
  cache_key="${wrapper_dir}|${_VIBEGUARD_RUNTIME:-}|${VIBEGUARD_RUNTIME:-}|${HOME:-}"
  if [[ "${_VG_CONFIG_RUNTIME_PATH_CACHE_KEY:-}" == "${cache_key}" ]]; then
    case "${_VG_CONFIG_RUNTIME_PATH_CACHE_STATE:-}" in
      hit)
        _VG_CONFIG_RUNTIME_PATH_RESULT="${_VG_CONFIG_RUNTIME_PATH_CACHE}"
        printf '%s\n' "${_VG_CONFIG_RUNTIME_PATH_CACHE}"
        return 0
        ;;
      miss)
        _VG_CONFIG_RUNTIME_PATH_RESULT=""
        return 1
        ;;
    esac
  fi

  while IFS= read -r candidate; do
    if [[ -n "${candidate}" && -f "${candidate}" && -x "${candidate}" ]]; then
      if _vg_config_runtime_supports "${candidate}"; then
        _VG_CONFIG_RUNTIME_PATH_CACHE_KEY="${cache_key}"
        _VG_CONFIG_RUNTIME_PATH_CACHE_STATE="hit"
        _VG_CONFIG_RUNTIME_PATH_CACHE="${candidate}"
        _VG_CONFIG_RUNTIME_PATH_RESULT="${candidate}"
        printf '%s\n' "${candidate}"
        return 0
      fi
    fi
  done < <(_vg_config_runtime_candidates "${wrapper_dir}")
  _VG_CONFIG_RUNTIME_PATH_CACHE_KEY="${cache_key}"
  _VG_CONFIG_RUNTIME_PATH_CACHE_STATE="miss"
  _VG_CONFIG_RUNTIME_PATH_CACHE=""
  _VG_CONFIG_RUNTIME_PATH_RESULT=""
  return 1
}

_vg_config_installed_context() {
  local wrapper_dir="$1" installed_hooks="${HOME:-}/.vibeguard/installed/hooks"
  [[ -n "${HOME:-}" && ( "${wrapper_dir}" == "${installed_hooks}" || "${wrapper_dir}" == "${installed_hooks}/"* ) ]]
}

_vg_config_runtime_candidates() {
  local wrapper_dir="$1"
  printf '%s\n' "${_VIBEGUARD_RUNTIME:-}"
  printf '%s\n' "${VIBEGUARD_RUNTIME:-}"
  if _vg_config_installed_context "${wrapper_dir}"; then
    printf '%s\n' "${HOME}/.vibeguard/installed/bin/vibeguard-runtime"
    printf '%s\n' "${wrapper_dir}/vibeguard-runtime"
    printf '%s\n' "${wrapper_dir}/../vibeguard-runtime/target/release/vibeguard-runtime"
    printf '%s\n' "${wrapper_dir}/../vibeguard-runtime/target/debug/vibeguard-runtime"
  else
    printf '%s\n' "${wrapper_dir}/../vibeguard-runtime/target/release/vibeguard-runtime"
    printf '%s\n' "${wrapper_dir}/../vibeguard-runtime/target/debug/vibeguard-runtime"
    printf '%s\n' "${HOME:-}/.vibeguard/installed/bin/vibeguard-runtime"
    printf '%s\n' "${wrapper_dir}/vibeguard-runtime"
  fi
}

_vg_config_runtime_supports() {
  local candidate="$1" probe_file validate_probe int_probe str_probe
  probe_file="${TMPDIR:-/tmp}/vibeguard-runtime-config-probe.$$.json"
  printf '{"u16":{"limit":19},"write_mode":"block"}\n' > "${probe_file}" || return 1
  validate_probe="$("${candidate}" runtime-config-validate "${probe_file}" 2>/dev/null)" || {
    rm -f "${probe_file}" 2>/dev/null || true
    return 1
  }
  [[ "${validate_probe}" == "VALID" ]] || { rm -f "${probe_file}" 2>/dev/null || true; return 1; }
  int_probe="$(
    _VG_CONFIG_FILE="${probe_file}" VIBEGUARD_CONFIG_FILE="${probe_file}" \
      "${candidate}" runtime-config-get-int __VIBEGUARD_CONFIG_PROBE_INT__ u16.limit 17 2>/dev/null
  )" || { rm -f "${probe_file}" 2>/dev/null || true; return 1; }
  [[ "${int_probe}" == "19" ]] || { rm -f "${probe_file}" 2>/dev/null || true; return 1; }
  str_probe="$(
    _VG_CONFIG_FILE="${probe_file}" VIBEGUARD_CONFIG_FILE="${probe_file}" \
      "${candidate}" runtime-config-get-str __VIBEGUARD_CONFIG_PROBE_STR__ write_mode probe-default 2>/dev/null
  )" || { rm -f "${probe_file}" 2>/dev/null || true; return 1; }
  [[ "${str_probe}" == "block" ]] || { rm -f "${probe_file}" 2>/dev/null || true; return 1; }
  rm -f "${probe_file}" 2>/dev/null || true
  return 0
}

vg_config_get_int_result() {
  local result_var="$1" env_name="$2" json_path="$3" default_val="$4"
  local config_val runtime_path config_file env_value

  config_file="$(_vg_config_file)"
  if _vg_config_runtime_path >/dev/null; then
    runtime_path="${_VG_CONFIG_RUNTIME_PATH_RESULT}"
    env_value="${!env_name:-}"
    if [[ -n "${env_value}" ]]; then
      config_val="$(_VG_CONFIG_FILE="${config_file}" VIBEGUARD_CONFIG_FILE="${config_file}" \
        env "${env_name}=${env_value}" \
        "${runtime_path}" runtime-config-get-int "$env_name" "$json_path" "$default_val")" || return 2
    else
      config_val="$(_VG_CONFIG_FILE="${config_file}" VIBEGUARD_CONFIG_FILE="${config_file}" \
        "${runtime_path}" runtime-config-get-int "$env_name" "$json_path" "$default_val")" || return 2
    fi
    if [[ -z "${config_val}" ]]; then
      printf 'VibeGuard runtime config read failed: empty integer result for %s\n' "$json_path" >&2
      return 2
    fi
    if [[ "$config_val" =~ ^[0-9]+$ ]]; then
      printf -v "$result_var" '%s' "$config_val"
      return 0
    fi
    printf 'VibeGuard runtime config read failed: invalid integer result for %s\n' "$json_path" >&2
    return 2
  elif [[ -e "$config_file" || -L "$config_file" ]]; then
    printf 'VibeGuard runtime config read failed: vibeguard-runtime with runtime-config-get-int is required to read %s\n' "$config_file" >&2
    return 2
  fi

  config_val="${!env_name:-}"
  if [[ -n "$config_val" && "$config_val" =~ ^[0-9]+$ ]]; then
    printf -v "$result_var" '%s' "$config_val"
    return 0
  fi
  printf -v "$result_var" '%s' "$default_val"
}

vg_config_get_int() {
  local val=""
  vg_config_get_int_result val "$@" || return $?
  printf '%s' "$val"
}

vg_config_get_str_result() {
  local result_var="$1" env_name="$2" json_path="$3" default_val="$4"
  local config_val runtime_path config_file env_value

  config_file="$(_vg_config_file)"
  if _vg_config_runtime_path >/dev/null; then
    runtime_path="${_VG_CONFIG_RUNTIME_PATH_RESULT}"
    env_value="${!env_name:-}"
    if [[ -n "${env_value}" ]]; then
      config_val="$(_VG_CONFIG_FILE="${config_file}" VIBEGUARD_CONFIG_FILE="${config_file}" \
        env "${env_name}=${env_value}" \
        "${runtime_path}" runtime-config-get-str "$env_name" "$json_path" "$default_val")" || return 2
    else
      config_val="$(_VG_CONFIG_FILE="${config_file}" VIBEGUARD_CONFIG_FILE="${config_file}" \
        "${runtime_path}" runtime-config-get-str "$env_name" "$json_path" "$default_val")" || return 2
    fi
    if [[ -z "${config_val}" ]]; then
      printf 'VibeGuard runtime config read failed: empty string result for %s\n' "$json_path" >&2
      return 2
    fi
    printf -v "$result_var" '%s' "$config_val"
    return 0
  elif [[ -e "$config_file" || -L "$config_file" ]]; then
    printf 'VibeGuard runtime config read failed: vibeguard-runtime with runtime-config-get-str is required to read %s\n' "$config_file" >&2
    return 2
  fi

  config_val="${!env_name:-}"
  if [[ -n "$config_val" ]]; then
    printf -v "$result_var" '%s' "$config_val"
    return 0
  fi
  printf -v "$result_var" '%s' "$default_val"
}

vg_config_get_str() {
  local val=""
  vg_config_get_str_result val "$@" || return $?
  printf '%s' "$val"
}

vg_u16_warn_limit_result() {
  local result_var="$1" hard_limit="$2"
  local config_warn_limit

  vg_config_get_int_result config_warn_limit VG_U16_WARN_LIMIT u16.warn_limit 400 || return $?
  if [[ "$config_warn_limit" -ge "$hard_limit" ]]; then
    printf -v "$result_var" '%s' "$hard_limit"
  else
    printf -v "$result_var" '%s' "$config_warn_limit"
  fi
}

vg_u16_warn_limit() {
  local val=""
  vg_u16_warn_limit_result val "$1" || return $?
  printf '%s' "$val"
}

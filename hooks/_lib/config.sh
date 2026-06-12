#!/usr/bin/env bash
# VibeGuard layered config reader.
#
# Resolution order:
#   1. Environment variable supplied by the caller.
#   2. JSON config file at $_VG_CONFIG_FILE / $VIBEGUARD_CONFIG_FILE, or
#      ${VIBEGUARD_LOG_DIR:-$HOME/.vibeguard}/config.json.
#   3. Caller-provided default.
#
# Standalone helper reads stay permissive for non-critical tuning fields. The
# wrapper policy gate validates malformed JSON before hooks execute, so parse
# errors cannot silently weaken runtime enforcement.

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
  local candidate="$1" probe_file int_probe str_probe
  probe_file="${TMPDIR:-/tmp}/vibeguard-runtime-config-probe.$$.json"
  printf '{"probe":{"int":19,"str":"probe-hit"}}\n' > "${probe_file}" || return 1
  int_probe="$(
    _VG_CONFIG_FILE="${probe_file}" VIBEGUARD_CONFIG_FILE="${probe_file}" \
      "${candidate}" runtime-config-get-int __VIBEGUARD_CONFIG_PROBE_INT__ probe.int 17 2>/dev/null
  )" || { rm -f "${probe_file}" 2>/dev/null || true; return 1; }
  [[ "${int_probe}" == "19" ]] || { rm -f "${probe_file}" 2>/dev/null || true; return 1; }
  str_probe="$(
    _VG_CONFIG_FILE="${probe_file}" VIBEGUARD_CONFIG_FILE="${probe_file}" \
      "${candidate}" runtime-config-get-str __VIBEGUARD_CONFIG_PROBE_STR__ probe.str probe-default 2>/dev/null
  )" || { rm -f "${probe_file}" 2>/dev/null || true; return 1; }
  [[ "${str_probe}" == "probe-hit" ]] || { rm -f "${probe_file}" 2>/dev/null || true; return 1; }
  rm -f "${probe_file}" 2>/dev/null || true
  return 0
}

vg_config_get_int_result() {
  local result_var="$1" env_name="$2" json_path="$3" default_val="$4"
  local config_val runtime_path config_file

  config_val="${!env_name:-}"
  if [[ -n "$config_val" && "$config_val" =~ ^[0-9]+$ ]]; then
    printf -v "$result_var" '%s' "$config_val"
    return 0
  fi

  config_file="$(_vg_config_file)"
  if _vg_config_runtime_path >/dev/null; then
    runtime_path="${_VG_CONFIG_RUNTIME_PATH_RESULT}"
    config_val="$(
      _VG_CONFIG_FILE="${config_file}" VIBEGUARD_CONFIG_FILE="${config_file}" \
        "${runtime_path}" runtime-config-get-int "$env_name" "$json_path" "$default_val" 2>/dev/null || true
    )"
    if [[ -n "$config_val" && "$config_val" =~ ^[0-9]+$ ]]; then
      printf -v "$result_var" '%s' "$config_val"
      return 0
    fi
  elif [[ -f "$config_file" ]]; then
    printf 'VibeGuard runtime config read failed: vibeguard-runtime with runtime-config-get-int is required to read %s\n' "$config_file" >&2
    return 2
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
  local config_val runtime_path config_file

  config_val="${!env_name:-}"
  if [[ -n "$config_val" ]]; then
    printf -v "$result_var" '%s' "$config_val"
    return 0
  fi

  config_file="$(_vg_config_file)"
  if _vg_config_runtime_path >/dev/null; then
    runtime_path="${_VG_CONFIG_RUNTIME_PATH_RESULT}"
    config_val="$(
      _VG_CONFIG_FILE="${config_file}" VIBEGUARD_CONFIG_FILE="${config_file}" \
        "${runtime_path}" runtime-config-get-str "$env_name" "$json_path" "$default_val" 2>/dev/null || true
    )"
    if [[ -n "$config_val" ]]; then
      printf -v "$result_var" '%s' "$config_val"
      return 0
    fi
  elif [[ -f "$config_file" ]]; then
    printf 'VibeGuard runtime config read failed: vibeguard-runtime with runtime-config-get-str is required to read %s\n' "$config_file" >&2
    return 2
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

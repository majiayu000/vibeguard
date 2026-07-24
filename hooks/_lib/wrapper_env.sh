#!/usr/bin/env bash
# Shared wrapper preflight for project log and session environment.

if [[ -n "${_VG_WRAPPER_ENV_SH_LOADED:-}" ]]; then
  return 0
fi
_VG_WRAPPER_ENV_SH_LOADED=1

_VG_WRAPPER_ENV_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

vg_wrapper_env_installed_context() {
  local wrapper_dir="$1" helper_dir="$2" home_prefix="${HOME:-}/.vibeguard"
  [[ -n "${HOME:-}" && ( \
    "${wrapper_dir}" == "${home_prefix}" || \
    "${wrapper_dir}" == "${home_prefix}/installed/hooks" || \
    "${helper_dir}" == "${home_prefix}/_lib" || \
    "${helper_dir}" == "${home_prefix}/installed/hooks/_lib" \
  ) ]]
}

vg_wrapper_env_runtime_candidates() {
  local wrapper_dir="$1" helper_dir="$2"
  printf '%s\n' "${VIBEGUARD_RUNTIME:-}"
  if vg_wrapper_env_installed_context "${wrapper_dir}" "${helper_dir}"; then
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

vg_wrapper_env_runtime_path() {
  local wrapper_dir helper_dir candidate candidates
  if [[ -n "${VG_WRAPPER_ENV_RUNTIME_PATH_CACHE:-}" && -x "${VG_WRAPPER_ENV_RUNTIME_PATH_CACHE}" ]]; then
    printf '%s\n' "${VG_WRAPPER_ENV_RUNTIME_PATH_CACHE}"
    return 0
  fi
  helper_dir="${_VG_WRAPPER_ENV_LIB_DIR}"
  wrapper_dir="${WRAPPER_DIR:-$(cd "${helper_dir}/.." && pwd)}"
  candidates="$(vg_wrapper_env_runtime_candidates "${wrapper_dir}" "${helper_dir}")"
  while IFS= read -r candidate; do
    if [[ -n "${candidate}" && -f "${candidate}" && -x "${candidate}" ]]; then
      VG_WRAPPER_ENV_RUNTIME_PATH_CACHE="${candidate}"
      printf '%s\n' "${candidate}"
      return 0
    fi
  done <<< "${candidates}"
  return 1
}

vg_wrapper_env_export_line() {
  local line="$1" key value
  key="${line%%=*}"
  value="${line#*=}"
  [[ "${key}" != "${line}" ]] || return 0
  case "${key}" in
    VIBEGUARD_CLI|VIBEGUARD_PROJECT_HASH|VIBEGUARD_PROJECT_LOG_DIR|VIBEGUARD_LOG_FILE|VIBEGUARD_SESSION_ID)
      export "${key}=${value}"
      ;;
  esac
}

# Derive writer identity from the Codex payload's logical session_id instead of
# the wrapper's short-lived parent PID (issue #673). Pre/post hooks of one tool
# call can run under different parent processes but share this payload field.
vg_wrapper_env_codex_session() {
  local input="$1" runtime_path logical_session
  [[ -z "${VIBEGUARD_SESSION_ID:-}" ]] || return 0
  [[ -n "${input}" ]] || return 0
  runtime_path="$(vg_wrapper_env_runtime_path)" || return 0
  logical_session="$(printf '%s' "${input}" | "${runtime_path}" codex-session-id 2>/dev/null | head -1)" || return 0
  [[ -n "${logical_session}" ]] || return 0
  export VIBEGUARD_SESSION_ID="${logical_session}"
  export VIBEGUARD_SESSION_SOURCE="codex-thread"
}

vg_wrapper_env_export() {
  local cli="${1:-unknown}" runtime_path output line
  export VIBEGUARD_CLI="${VIBEGUARD_CLI:-${cli}}"
  if [[ -n "${VIBEGUARD_PROJECT_HASH:-}" \
    && -n "${VIBEGUARD_PROJECT_LOG_DIR:-}" \
    && -n "${VIBEGUARD_LOG_FILE:-}" \
    && -n "${VIBEGUARD_SESSION_ID:-}" ]]; then
    return 0
  fi
  runtime_path="$(vg_wrapper_env_runtime_path)" || return 0
  output="$(VIBEGUARD_WRAPPER_PARENT_PID="${PPID:-}" "${runtime_path}" wrapper-env "${cli}" 2>/dev/null)" || return 0
  while IFS= read -r line; do
    vg_wrapper_env_export_line "${line}"
  done <<< "${output}"
}

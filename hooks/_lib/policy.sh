#!/usr/bin/env bash
# Shared runtime policy gate for VibeGuard hook wrappers.

if [[ -n "${_VG_POLICY_SH_LOADED:-}" ]]; then
  return 0
fi
_VG_POLICY_SH_LOADED=1

_VG_POLICY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

vg_policy_user_config_file() {
  printf '%s' "${_VG_CONFIG_FILE:-${VIBEGUARD_CONFIG_FILE:-${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}/config.json}}"
}

vg_policy_runtime_path() {
  local helper_dir wrapper_dir candidate
  if [[ -n "${VG_POLICY_RUNTIME_PATH_CACHE:-}" && -x "${VG_POLICY_RUNTIME_PATH_CACHE}" ]]; then
    printf '%s\n' "${VG_POLICY_RUNTIME_PATH_CACHE}"
    return 0
  fi
  helper_dir="${_VG_POLICY_LIB_DIR}"
  wrapper_dir="${WRAPPER_DIR:-$(cd "${helper_dir}/.." && pwd)}"
  while IFS= read -r candidate; do
    if [[ -n "${candidate}" && -f "${candidate}" && -x "${candidate}" ]]; then
      if vg_policy_runtime_supports "${candidate}"; then
        VG_POLICY_RUNTIME_PATH_CACHE="${candidate}"
        printf '%s\n' "${candidate}"
        return 0
      fi
    fi
  done < <(vg_policy_runtime_candidates "${wrapper_dir}" "${helper_dir}")
  return 1
}

vg_policy_installed_context() {
  local wrapper_dir="$1" helper_dir="$2" home_prefix="${HOME:-}/.vibeguard"
  [[ -n "${HOME:-}" && ( \
    "${wrapper_dir}" == "${home_prefix}" || \
    "${wrapper_dir}" == "${home_prefix}/installed/hooks" || \
    "${helper_dir}" == "${home_prefix}/installed/hooks/_lib" \
  ) ]]
}

vg_policy_runtime_candidates() {
  local wrapper_dir="$1" helper_dir="$2"
  printf '%s\n' "${VIBEGUARD_POLICY_RUNTIME:-}"
  printf '%s\n' "${VIBEGUARD_RUNTIME:-}"
  if vg_policy_installed_context "${wrapper_dir}" "${helper_dir}"; then
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

vg_policy_runtime_supports() {
  local candidate="$1" support_probe policy_probe probe_diag downgrade_probe codex_probe
  support_probe="$("${candidate}" runtime-policy-supports 2>/dev/null)" || support_probe=""
  if [[ "${support_probe}" == *"runtime-policy-json-v1"* ]]; then
    return 0
  fi
  probe_diag="${TMPDIR:-/tmp}/vibeguard-policy-probe.$$.jsonl"
  policy_probe="$(
    VIBEGUARD_PROJECT_CONFIG="${TMPDIR:-/tmp}/vibeguard-missing-policy-probe.json" \
    VIBEGUARD_USER_CONFIG_FILE="" \
      "${candidate}" runtime-policy-check --cwd "${TMPDIR:-/tmp}" __vibeguard_policy_probe__ 2>/dev/null
  )" || return 1
  [[ "${policy_probe}" == *'"decision"'* && "${policy_probe}" == *'"run"'* ]] || return 1
  downgrade_probe="$(printf '{"decision":"block","reason":"probe"}' \
    | "${candidate}" runtime-policy-downgrade-output 2>/dev/null)" || return 1
  [[ "${downgrade_probe}" == *'"decision"'* && "${downgrade_probe}" == *'"warn"'* ]] || return 1
  codex_probe="$(printf 'probe' \
    | "${candidate}" runtime-policy-codex-error PreToolUse 2>/dev/null)" || return 1
  [[ "${codex_probe}" == *'"permissionDecision"'* && "${codex_probe}" == *'"deny"'* ]] || return 1
  rm -f "${probe_diag}" 2>/dev/null || true
  printf 'probe' \
    | "${candidate}" runtime-policy-diag "${probe_diag}" __vibeguard_policy_probe__ PreToolUse policy_error probe >/dev/null 2>&1 || return 1
  [[ -s "${probe_diag}" ]] || return 1
  rm -f "${probe_diag}" 2>/dev/null || true
  return 0
}

vg_policy_current_cwd() {
  pwd -P 2>/dev/null || pwd
}

vg_policy_json_field() {
  local runtime_path="$1" output="$2" field_path="$3"
  printf '%s' "${output}" | "${runtime_path}" json-field "${field_path}" 2>/dev/null || true
}

vg_policy_reason_from_output() {
  local runtime_path="$1" output="$2" reason
  reason="$(vg_policy_json_field "${runtime_path}" "${output}" reason)"
  if [[ -n "${reason}" ]]; then
    printf '%s' "${reason}"
  else
    printf '%s' "${output}"
  fi
}

vg_policy_check_hook() {
  local hook_name="$1"
  local output status runtime_path project_cwd enforcement

  VG_POLICY_REASON=""
  VG_POLICY_KIND=""
  VG_POLICY_ENFORCEMENT="block"
  VG_POLICY_RUNTIME_PATH=""
  export VIBEGUARD_POLICY_ENFORCEMENT="block"

  if ! runtime_path="$(vg_policy_runtime_path)"; then
    VG_POLICY_REASON="VibeGuard policy error: vibeguard-runtime is required for runtime policy checks."
    VG_POLICY_KIND="policy_error"
    return 20
  fi
  VG_POLICY_RUNTIME_PATH="${runtime_path}"

  status=0
  project_cwd="$(vg_policy_current_cwd)"
  output="$(
    VIBEGUARD_USER_CONFIG_FILE="$(vg_policy_user_config_file)" \
      "${runtime_path}" runtime-policy-check --cwd "${project_cwd}" "${hook_name}" 2>&1
  )" || status=$?

  case "${status}" in
    0)
      enforcement="$(vg_policy_json_field "${runtime_path}" "${output}" enforcement)"
      if [[ "${enforcement}" == "warn" || "${output}" == *"enforcement=warn"* ]]; then
        VG_POLICY_REASON="$(vg_policy_reason_from_output "${runtime_path}" "${output}")"
        VG_POLICY_KIND="policy_warn"
        VG_POLICY_ENFORCEMENT="warn"
        export VIBEGUARD_POLICY_ENFORCEMENT="warn"
      fi
      return 0
      ;;
    10)
      VG_POLICY_REASON="$(vg_policy_reason_from_output "${runtime_path}" "${output}")"
      VG_POLICY_KIND="policy_skip"
      return 10
      ;;
    30)
      VG_POLICY_REASON="$(vg_policy_reason_from_output "${runtime_path}" "${output}")"
      VG_POLICY_KIND="config_parse_error"
      return 30
      ;;
    *)
      VG_POLICY_REASON="$(vg_policy_reason_from_output "${runtime_path}" "${output}")"
      VG_POLICY_REASON="${VG_POLICY_REASON:-VibeGuard policy error: unknown runtime policy failure.}"
      VG_POLICY_KIND="policy_error"
      return 20
      ;;
  esac
}

vg_policy_downgrade_output() {
  local output="$1" runtime_path
  if [[ "${VIBEGUARD_POLICY_ENFORCEMENT:-}" != "warn" || -z "${output}" ]]; then
    printf '%s\n' "${output}"
    return 0
  fi

  runtime_path="${VG_POLICY_RUNTIME_PATH:-}"
  if [[ -z "${runtime_path}" ]] && ! runtime_path="$(vg_policy_runtime_path)"; then
    printf 'VibeGuard policy error: vibeguard-runtime is required for warn-mode output downgrade.\n' >&2
    printf '%s\n' "${output}"
    return 0
  fi

  printf '%s' "${output}" | "${runtime_path}" runtime-policy-downgrade-output || {
    printf 'VibeGuard policy error: runtime-policy-downgrade-output failed.\n' >&2
    printf '%s\n' "${output}"
  }
}

vg_policy_diag() {
  local hook_name="$1" event_name="${2:-}" kind="$3" reason="$4"
  local diag_file diag_dir
  diag_file="${VIBEGUARD_POLICY_DIAG_FILE:-${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}/policy.jsonl}"
  diag_dir="$(dirname "${diag_file}")"
  mkdir -p "${diag_dir}" 2>/dev/null || return 0
  local runtime_path
  runtime_path="${VG_POLICY_RUNTIME_PATH:-}"
  if [[ -z "${runtime_path}" ]] && ! runtime_path="$(vg_policy_runtime_path)"; then
    return 0
  fi
  printf '%s' "${reason}" \
    | "${runtime_path}" runtime-policy-diag \
      "${diag_file}" \
      "${hook_name}" \
      "${event_name}" \
      "${kind}" \
      "${VIBEGUARD_WRAPPER:-unknown}" >/dev/null 2>/dev/null || true
}

vg_policy_codex_error_output() {
  local event_name="$1" reason="$2" runtime_path
  runtime_path="${VG_POLICY_RUNTIME_PATH:-}"
  if [[ -z "${runtime_path}" ]] && ! runtime_path="$(vg_policy_runtime_path)"; then
    vg_policy_codex_error_fallback "${event_name}"
    return 0
  fi
  printf '%s' "${reason}" | "${runtime_path}" runtime-policy-codex-error "${event_name}" || {
    vg_policy_codex_error_fallback "${event_name}"
  }
}

vg_policy_codex_error_fallback() {
  local event_name="$1"
  local reason="VibeGuard policy error: vibeguard-runtime is required for Codex policy output."
  case "${event_name}" in
    PreToolUse)
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "${reason}"
      ;;
    PermissionRequest)
      printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"%s"}}}\n' "${reason}"
      ;;
    PostToolUse)
      printf '{"decision":"block","reason":"%s","hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "${reason}" "${reason}"
      ;;
    Stop)
      printf '{"stopReason":"%s"}\n' "${reason}"
      ;;
    *)
      printf '{"systemMessage":"%s"}\n' "${reason}"
      ;;
  esac
}

vg_policy_codex_gate() {
  local hook_name="$1" event_name="$2" policy_status=0
  vg_policy_check_hook "${hook_name}" || policy_status=$?
  [[ ${policy_status} -eq 0 ]] && return 0

  vg_policy_diag "${hook_name}" "${event_name}" "${VG_POLICY_KIND}" "${VG_POLICY_REASON}"
  if declare -F codex_diag >/dev/null 2>&1; then
    codex_diag "${hook_name}" "${event_name}" "${VG_POLICY_KIND}" "${VG_POLICY_REASON}"
  fi
  [[ ${policy_status} -eq 10 ]] && return 1
  vg_policy_codex_error_output "${event_name}" "${VG_POLICY_REASON}"
  return 1
}

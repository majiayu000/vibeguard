#!/usr/bin/env bash
# Shared runtime policy gate for VibeGuard hook wrappers.

if [[ -n "${_VG_POLICY_SH_LOADED:-}" ]]; then
  return 0
fi
_VG_POLICY_SH_LOADED=1

_VG_POLICY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

vg_policy_runtime_path() {
  local candidate
  for candidate in \
    "${VIBEGUARD_RUNTIME:-}" \
    "${_VIBEGUARD_RUNTIME:-}" \
    "${_VG_POLICY_LIB_DIR}/../../vibeguard-runtime/target/debug/vibeguard-runtime" \
    "${_VG_POLICY_LIB_DIR}/../../vibeguard-runtime/target/release/vibeguard-runtime" \
    "${HOME}/.vibeguard/installed/bin/vibeguard-runtime" \
    "${_VG_POLICY_LIB_DIR}/../vibeguard-runtime"; do
    if [[ -n "${candidate}" && -f "${candidate}" && -x "${candidate}" ]]; then
      if VIBEGUARD_PROJECT_CONFIG="${TMPDIR:-/tmp}/vibeguard-missing-policy-probe.json" \
          VIBEGUARD_USER_CONFIG_FILE="" \
          "${candidate}" runtime-policy-check __vibeguard_policy_probe__ --cwd "${TMPDIR:-/tmp}" >/dev/null 2>&1; then
        printf '%s\n' "${candidate}"
        return 0
      fi
    fi
  done
  return 1
}

vg_policy_user_config_file() {
  printf '%s' "${_VG_CONFIG_FILE:-${VIBEGUARD_CONFIG_FILE:-${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}/config.json}}"
}

vg_policy_check_hook() {
  local hook_name="$1"
  local output status runtime_path

  VG_POLICY_REASON=""
  VG_POLICY_KIND=""
  VG_POLICY_ENFORCEMENT="block"
  export VIBEGUARD_POLICY_ENFORCEMENT="block"

  if ! runtime_path="$(vg_policy_runtime_path)"; then
    VG_POLICY_REASON="VibeGuard policy error: vibeguard-runtime is required for runtime policy checks."
    VG_POLICY_KIND="policy_error"
    return 20
  fi

  status=0
  output="$(
    VIBEGUARD_USER_CONFIG_FILE="$(vg_policy_user_config_file)" \
      "${runtime_path}" runtime-policy-check "${hook_name}" 2>&1
  )" || status=$?

  case "${status}" in
    0)
      if [[ "${output}" == *"enforcement=warn"* ]]; then
        VG_POLICY_REASON="${output}"
        VG_POLICY_KIND="policy_warn"
        VG_POLICY_ENFORCEMENT="warn"
        export VIBEGUARD_POLICY_ENFORCEMENT="warn"
      fi
      return 0
      ;;
    10)
      VG_POLICY_REASON="${output}"
      VG_POLICY_KIND="policy_skip"
      return 10
      ;;
    30)
      VG_POLICY_REASON="${output}"
      VG_POLICY_KIND="config_parse_error"
      return 30
      ;;
    *)
      VG_POLICY_REASON="${output:-VibeGuard policy error: unknown runtime policy failure.}"
      VG_POLICY_KIND="policy_error"
      return 20
      ;;
  esac
}

vg_policy_downgrade_output() {
  local output="$1"
  local runtime_path runtime_output status
  if [[ "${VIBEGUARD_POLICY_ENFORCEMENT:-}" != "warn" || -z "${output}" ]]; then
    printf '%s\n' "${output}"
    return 0
  fi

  if ! runtime_path="$(vg_policy_runtime_path)"; then
    printf '%s\n' "VibeGuard policy error: vibeguard-runtime missing during warn-mode downgrade." >&2
    printf '%s\n' "${output}"
    return 0
  fi
  status=0
  runtime_output="$(printf '%s' "${output}" | "${runtime_path}" runtime-policy-downgrade-output 2>/dev/null)" || status=$?
  if [[ "${status}" -eq 0 ]]; then
    printf '%s\n' "${runtime_output}"
  else
    printf '%s\n' "VibeGuard policy error: runtime-policy-downgrade-output failed." >&2
    printf '%s\n' "${output}"
  fi
}

vg_policy_diag() {
  local hook_name="$1" event_name="${2:-}" kind="$3" reason="$4"
  local diag_file diag_dir runtime_path
  diag_file="${VIBEGUARD_POLICY_DIAG_FILE:-${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}/policy.jsonl}"
  diag_dir="$(dirname "${diag_file}")"
  mkdir -p "${diag_dir}" 2>/dev/null || return 0
  runtime_path="$(vg_policy_runtime_path)" || return 0
  printf '%s' "${reason}" \
    | "${runtime_path}" runtime-policy-diag "${diag_file}" "${hook_name}" "${event_name}" "${kind}" "${VIBEGUARD_WRAPPER:-unknown}" \
    >/dev/null 2>&1 || true
}

vg_policy_json_escape() {
  local text="$1"
  text="${text//\\/\\\\}"
  text="${text//\"/\\\"}"
  text="${text//$'\n'/\\n}"
  text="${text//$'\r'/\\r}"
  text="${text//$'\t'/\\t}"
  printf '%s' "${text}"
}

vg_policy_codex_error_output() {
  local event_name="$1" reason="$2"
  local runtime_path escaped
  if runtime_path="$(vg_policy_runtime_path)"; then
    if printf '%s' "${reason}" | "${runtime_path}" runtime-policy-codex-error "${event_name}" 2>/dev/null; then
      return 0
    fi
  fi
  escaped="$(vg_policy_json_escape "${reason}")"
  case "${event_name}" in
    PreToolUse)
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "${escaped}"
      ;;
    PermissionRequest)
      printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"%s"}}}\n' "${escaped}"
      ;;
    PostToolUse)
      printf '{"decision":"block","reason":"%s","hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "${escaped}" "${escaped}"
      ;;
    Stop)
      printf '{"stopReason":"%s"}\n' "${escaped}"
      ;;
    *)
      printf '{"systemMessage":"%s"}\n' "${escaped}"
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

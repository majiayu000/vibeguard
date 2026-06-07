#!/usr/bin/env bash
# Codex wrapper diagnostics and tiny JSON helpers.

codex_runtime_path() {
  local helper_dir wrapper_dir candidate
  if [[ -n "${CODEX_RUNTIME_PATH_CACHE:-}" && -x "${CODEX_RUNTIME_PATH_CACHE}" ]]; then
    printf '%s\n' "${CODEX_RUNTIME_PATH_CACHE}"
    return 0
  fi
  helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  wrapper_dir="${WRAPPER_DIR:-$(cd "${helper_dir}/.." && pwd)}"
  for candidate in \
    "${VIBEGUARD_RUNTIME:-}" \
    "${wrapper_dir}/../vibeguard-runtime/target/debug/vibeguard-runtime" \
    "${wrapper_dir}/../vibeguard-runtime/target/release/vibeguard-runtime" \
    "${HOME}/.vibeguard/installed/bin/vibeguard-runtime" \
    "${wrapper_dir}/vibeguard-runtime"; do
    if [[ -n "${candidate}" && -f "${candidate}" && -x "${candidate}" ]]; then
      CODEX_RUNTIME_PATH_CACHE="${candidate}"
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

codex_runtime_stdin() {
  local command_name="$1" input="$2" runtime_path
  if ! runtime_path="$(codex_runtime_path)"; then
    return 127
  fi
  printf '%s' "${input}" | "${runtime_path}" "${command_name}"
}

_codex_json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/ }"
  value="${value//$'\r'/ }"
  value="${value//$'\t'/ }"
  printf '%s' "${value}"
}

codex_raw_event_name() {
  local input="$1"
  if codex_runtime_stdin "codex-event-name" "${input}" 2>/dev/null; then
    return 0
  fi
  if [[ "${input}" =~ \"hook_event_name\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '\n'
  fi
}

codex_pretool_deny_raw() {
  local reason="$1" escaped_reason
  if codex_runtime_stdin "codex-pretool-deny" "${reason}" 2>/dev/null; then
    return 0
  fi
  escaped_reason="$(_codex_json_escape "${reason}")"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "${escaped_reason}"
}

codex_permission_deny_raw() {
  local reason="$1" escaped_reason
  if codex_runtime_stdin "codex-permission-deny" "${reason}" 2>/dev/null; then
    return 0
  fi
  escaped_reason="$(_codex_json_escape "${reason}")"
  printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"%s"}}}\n' "${escaped_reason}"
}

codex_visible_failure_raw() {
  local event_name="$1" reason="$2"
  local runtime_path
  if runtime_path="$(codex_runtime_path 2>/dev/null)" && printf '%s' "${reason}" | "${runtime_path}" codex-visible-failure "${event_name}" 2>/dev/null; then
    return 0
  fi
  local escaped_reason
  escaped_reason="$(_codex_json_escape "${reason}")"
  case "${event_name}" in
    PreToolUse) codex_pretool_deny_raw "${reason}" ;;
    PermissionRequest) codex_permission_deny_raw "${reason}" ;;
    Stop) printf '{"stopReason":"%s"}\n' "${escaped_reason}" ;;
    PostToolUse) printf '{"decision":"block","reason":"%s","hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "${escaped_reason}" "${escaped_reason}" ;;
    *) printf '{"systemMessage":"%s"}\n' "${escaped_reason}" ;;
  esac
}

codex_set_caller_identity() {
  local event_name="$1"
  export VIBEGUARD_WRAPPER="${VIBEGUARD_WRAPPER:-run-hook-codex.sh}"
  export VIBEGUARD_SOURCE_CONFIG="${VIBEGUARD_SOURCE_CONFIG:-${HOME}/.codex/hooks.json}"
  export VIBEGUARD_HOOK_PROTOCOL_VERSION="${VIBEGUARD_HOOK_PROTOCOL_VERSION:-codex-hooks-v1}"
  if [[ -n "${event_name}" ]]; then
    export VIBEGUARD_AGENT_TYPE="codex"
    export VIBEGUARD_CLI="codex"
    export VIBEGUARD_CLIENT="codex"
    export VIBEGUARD_CLIENT_VARIANT="codex-cli-hooks"
    export VIBEGUARD_CALLER_EVIDENCE="codex-hook-payload"
  else
    export VIBEGUARD_CLIENT="${VIBEGUARD_CLIENT:-unknown}"
    export VIBEGUARD_CLIENT_VARIANT="${VIBEGUARD_CLIENT_VARIANT:-unknown}"
    export VIBEGUARD_CALLER_EVIDENCE="${VIBEGUARD_CALLER_EVIDENCE:-missing-codex-hook-payload}"
  fi
}

codex_diag() {
  local hook_name="$1" event_name="$2" reason="$3" detail="${4:-}"
  local diag_file="${VIBEGUARD_CODEX_DIAG_FILE:-${HOME}/.vibeguard/codex-wrapper.jsonl}"
  local runtime_path
  runtime_path="$(codex_runtime_path 2>/dev/null)" || return 0
  "${runtime_path}" codex-diag "${diag_file}" "${hook_name}" "${event_name}" "${reason}" "${detail}" "${PWD}" 2>/dev/null || true
}

codex_hook_timeout_ms() {
  local hook_name="$1"
  case "${hook_name}" in
    *post-build-check*) printf '%s\n' "35000" ;;
    *stop-guard*|*learn-evaluator*) printf '%s\n' "15000" ;;
    *pre-*|*post-edit*|*post-write*) printf '%s\n' "15000" ;;
    *) printf '%s\n' "" ;;
  esac
}

codex_hook_status_info() {
  local input="$1" parsed
  if parsed=$(codex_runtime_stdin "codex-status-info" "${input}" 2>/dev/null); then
    printf '%s\n' "${parsed}"
    return 0
  fi
  printf '%s\t%s\t%s\n' \
    "$(codex_raw_event_name "${input}")" \
    "$(codex_hook_status_matcher "${input}" 2>/dev/null || true)" \
    "$(codex_hook_status_detail "${input}" 2>/dev/null || true)"
}

codex_hook_status_detail() {
  local input="$1"
  if codex_runtime_stdin "codex-status-detail" "${input}" 2>/dev/null; then
    return 0
  fi
  printf '\n'
}

codex_hook_status_matcher() {
  local input="$1"
  if codex_runtime_stdin "codex-status-matcher" "${input}" 2>/dev/null; then
    return 0
  fi
  printf '\n'
}

codex_hook_start_info() {
  local input="$1" hook_name="$2" timeout_ms="${3:-}"
  local diag_file="${VIBEGUARD_CODEX_DIAG_FILE:-${HOME}/.vibeguard/codex-wrapper.jsonl}"
  local runtime_path
  runtime_path="$(codex_runtime_path 2>/dev/null)" || return 127
  printf '%s' "${input}" | "${runtime_path}" codex-hook-start "${diag_file}" "${hook_name}" "${timeout_ms}"
}

codex_hook_status() {
  local hook_name="$1" event_name="$2" matcher="$3" status="$4" reason="${5:-}" detail="${6:-}"
  local timeout_ms="${7:-}"
  local diag_file="${VIBEGUARD_CODEX_DIAG_FILE:-${HOME}/.vibeguard/codex-wrapper.jsonl}"
  local runtime_path
  runtime_path="$(codex_runtime_path 2>/dev/null)" || return 0
  "${runtime_path}" codex-hook-status "${diag_file}" "${hook_name}" "${event_name}" "${matcher}" "${status}" "${reason}" "${detail}" "${timeout_ms}" 2>/dev/null || true
}

codex_hook_status_from_output() {
  local hook_name="$1" event_name="$2" matcher="$3" hook_output="$4" detail="${5:-}" timeout_ms="${6:-}"
  local diag_file="${VIBEGUARD_CODEX_DIAG_FILE:-${HOME}/.vibeguard/codex-wrapper.jsonl}"
  local runtime_path parsed hook_status hook_reason
  if runtime_path="$(codex_runtime_path 2>/dev/null)" \
    && printf '%s' "${hook_output}" | "${runtime_path}" codex-hook-status-from-output \
      "${diag_file}" "${hook_name}" "${event_name}" "${matcher}" "${detail}" "${timeout_ms}" 2>/dev/null; then
    return 0
  fi
  if parsed=$(codex_runtime_stdin "codex-status-from-output" "${hook_output}" 2>/dev/null); then
    hook_status="${parsed%%$'\t'*}"
    hook_reason="${parsed#*$'\t'}"
    if [[ "${hook_status}" == "${parsed}" ]]; then
      hook_reason=""
    fi
    [[ -n "${hook_status}" ]] || hook_status="hook_error"
    codex_hook_status "${hook_name}" "${event_name}" "${matcher}" "${hook_status}" "${hook_reason}" "${detail}" "${timeout_ms}"
    return 0
  fi
  codex_hook_status "${hook_name}" "${event_name}" "${matcher}" "hook_error" "runtime-unavailable" "${detail}" "${timeout_ms}"
}

codex_finalize_output() {
  local hook_name="$1" event_name="$2" matcher="$3" hook_output="$4" detail="${5:-}" timeout_ms="${6:-}"
  local diag_file="${VIBEGUARD_CODEX_DIAG_FILE:-${HOME}/.vibeguard/codex-wrapper.jsonl}"
  local runtime_path
  runtime_path="$(codex_runtime_path 2>/dev/null)" || return 127
  printf '%s' "${hook_output}" | "${runtime_path}" codex-finalize-output \
    "${diag_file}" "${hook_name}" "${event_name}" "${matcher}" "${detail}" "${timeout_ms}"
}

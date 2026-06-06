#!/usr/bin/env bash
# Shared Codex hook output adapter.

_codex_runtime_adapter() {
  local command_name="$1" input="$2" status
  if ! declare -F codex_runtime_stdin >/dev/null 2>&1; then
    return 127
  fi
  codex_runtime_stdin "${command_name}" "${input}" 2>/dev/null
  status=$?
  case "${status}" in
    0|3) return "${status}" ;;
    2|127) return 127 ;;
    *) return "${status}" ;;
  esac
}

codex_event_name() {
  local input="$1"
  if declare -F codex_runtime_stdin >/dev/null 2>&1 && codex_runtime_stdin "codex-event-name" "${input}" 2>/dev/null; then
    return 0
  fi
  if declare -F codex_raw_event_name >/dev/null 2>&1; then
    codex_raw_event_name "${input}"
    return 0
  fi
  printf '\n'
}

codex_pretool_deny() {
  local reason="$1" escaped_reason
  local runtime_status=0
  _codex_runtime_adapter "codex-pretool-deny" "${reason}" || runtime_status=$?
  if [[ "${runtime_status}" -eq 0 ]]; then
    return "${runtime_status}"
  fi
  if [[ "${runtime_status}" -eq 3 ]]; then
    return "${runtime_status}"
  fi
  if declare -F _codex_json_escape >/dev/null 2>&1; then
    escaped_reason="$(_codex_json_escape "${reason}")"
  else
    escaped_reason="VIBEGUARD hook failed: Codex deny adapter unavailable."
  fi
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "${escaped_reason}"
  return 0
}

codex_permission_deny() {
  local reason="$1" escaped_reason
  local runtime_status=0
  _codex_runtime_adapter "codex-permission-deny" "${reason}" || runtime_status=$?
  if [[ "${runtime_status}" -eq 0 ]]; then
    return "${runtime_status}"
  fi
  if [[ "${runtime_status}" -eq 3 ]]; then
    return "${runtime_status}"
  fi
  if declare -F _codex_json_escape >/dev/null 2>&1; then
    escaped_reason="$(_codex_json_escape "${reason}")"
  else
    escaped_reason="VIBEGUARD hook failed: Codex deny adapter unavailable."
  fi
  printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"%s"}}}\n' "${escaped_reason}"
  return 0
}

codex_adapt_pretool() {
  local hook_output="$1"
  local runtime_status=0
  _codex_runtime_adapter "codex-adapt-pretool" "${hook_output}" || runtime_status=$?
  if [[ "${runtime_status}" -eq 0 || "${runtime_status}" -eq 3 ]]; then
    return "${runtime_status}"
  fi
  if [[ "${runtime_status}" -ne 127 ]]; then
    return "${runtime_status}"
  fi
  return 127
}

codex_adapt_posttool() {
  local hook_output="$1"
  local runtime_status=0
  _codex_runtime_adapter "codex-adapt-posttool" "${hook_output}" || runtime_status=$?
  if [[ "${runtime_status}" -eq 0 || "${runtime_status}" -eq 3 ]]; then
    return "${runtime_status}"
  fi
  if [[ "${runtime_status}" -ne 127 ]]; then
    return "${runtime_status}"
  fi
  return 127
}

codex_adapt_permission_request() {
  local hook_output="$1"
  local runtime_status=0
  _codex_runtime_adapter "codex-adapt-permission-request" "${hook_output}" || runtime_status=$?
  if [[ "${runtime_status}" -eq 0 || "${runtime_status}" -eq 3 ]]; then
    return "${runtime_status}"
  fi
  if [[ "${runtime_status}" -ne 127 ]]; then
    return "${runtime_status}"
  fi
  return 127
}

#!/usr/bin/env bash
# Codex wrapper execution loop. Keep run-hook-codex.sh as a thin dispatcher.

_codex_normalize_apply_patch_runtime() {
  local hook_name="$1" input="$2" runtime_path
  if ! declare -F codex_runtime_path >/dev/null 2>&1; then
    return 127
  fi
  if ! runtime_path="$(codex_runtime_path)"; then
    return 127
  fi
  printf '%s' "${input}" | "${runtime_path}" codex-normalize-apply-patch "${hook_name}"
}

_codex_input_looks_apply_patch() {
  local input="$1"
  [[ "${input}" == *'"tool_name":"apply_patch"'* \
    || "${input}" == *'"tool_name": "apply_patch"'* \
    || "${input}" == *"*** Begin Patch"* ]]
}

_codex_normalizer_fail_closed() {
  local event_name="$1"
  codex_visible_failure_raw "${event_name}" "VIBEGUARD hook failed: Codex apply_patch normalizer failed."
}

_codex_write_normalized_inputs() {
  local hook_name="$1" input="$2" normalized_file="$3"
  local status=0 stderr_file stderr_text

  if ! _codex_input_looks_apply_patch "${input}"; then
    printf '%s\n' "${input}" >"${normalized_file}"
    return 0
  fi

  if stderr_file="$(mktemp "${TMPDIR:-/tmp}/vibeguard-codex-normalizer.XXXXXX")"; then
    if _codex_normalize_apply_patch_runtime "${hook_name}" "${input}" >"${normalized_file}" 2>"${stderr_file}"; then
      rm -f "${stderr_file}" 2>/dev/null || true
      return 0
    else
      status=$?
    fi
    stderr_text="$(cat "${stderr_file}" 2>/dev/null || true)"
    rm -f "${stderr_file}" 2>/dev/null || true

    if [[ "${status}" -ne 0 ]]; then
      codex_diag "${hook_name}" "${EVENT_NAME}" "normalizer-failed" "${stderr_text:-runtime exit ${status}}"
      return 1
    fi
  fi

  codex_diag "${hook_name}" "${EVENT_NAME}" "normalizer-failed" "runtime unavailable"
  return 1
}

codex_run_hook() {
  local hook_name="$1" hook_path="$2" input="$3"
  shift 3

  local normalized_file
  normalized_file="$(mktemp "${TMPDIR:-/tmp}/vibeguard-codex-inputs.XXXXXX")"
  if ! _codex_write_normalized_inputs "${hook_name}" "${input}" "${normalized_file}"; then
    rm -f "${normalized_file}" 2>/dev/null || true
    _codex_normalizer_fail_closed "${EVENT_NAME}"
    return 0
  fi

  local first_adapted_output=""
  local normalized_input hook_output hook_exit hook_err_file hook_err event_name
  local pretool_status pretool_output permission_status permission_output
  local posttool_status posttool_output
  while IFS= read -r normalized_input || [[ -n "${normalized_input:-}" ]]; do
    [[ -n "${normalized_input}" ]] || continue

    hook_err_file="$(mktemp "${TMPDIR:-/tmp}/vibeguard-codex-hook.XXXXXX")"
    event_name=$(codex_event_name "${normalized_input}")
    local hook_matcher hook_detail hook_timeout_ms hook_status_info
    local hook_timeout_seconds
    if declare -F codex_hook_status_info >/dev/null 2>&1; then
      hook_status_info="$(codex_hook_status_info "${normalized_input}" 2>/dev/null || true)"
      event_name="${hook_status_info%%$'\t'*}"
      hook_status_info="${hook_status_info#*$'\t'}"
      hook_matcher="${hook_status_info%%$'\t'*}"
      hook_detail="${hook_status_info#*$'\t'}"
      if [[ "${hook_matcher}" == "${hook_status_info}" ]]; then
        hook_detail=""
      fi
    else
      event_name=$(codex_event_name "${normalized_input}")
      hook_matcher="$(codex_hook_status_matcher "${normalized_input}" 2>/dev/null || true)"
      hook_detail="$(codex_hook_status_detail "${normalized_input}" 2>/dev/null || true)"
    fi
    [[ -n "${event_name}" ]] || event_name=$(codex_event_name "${normalized_input}")
    hook_timeout_ms="$(codex_hook_timeout_ms "${hook_name}" 2>/dev/null || true)"
    codex_hook_status "${hook_name}" "${event_name}" "${hook_matcher}" "running" "" "${hook_detail}" "${hook_timeout_ms}"

    hook_output=""
    hook_exit=0
    hook_timeout_seconds=""
    if [[ "${hook_timeout_ms}" =~ ^[0-9]+$ && "${hook_timeout_ms}" -gt 0 ]]; then
      hook_timeout_seconds=$(( (hook_timeout_ms + 999) / 1000 ))
    fi
    if [[ -n "${hook_timeout_seconds}" ]] && declare -F vg_run_with_timeout >/dev/null 2>&1; then
      hook_output=$(printf '%s' "${normalized_input}" | vg_run_with_timeout "${hook_timeout_seconds}" bash "${hook_path}" "$@" 2>"${hook_err_file}") || hook_exit=$?
    else
      hook_output=$(printf '%s' "${normalized_input}" | bash "${hook_path}" "$@" 2>"${hook_err_file}") || hook_exit=$?
    fi
    hook_err="$(cat "${hook_err_file}" 2>/dev/null || true)"
    rm -f "${hook_err_file}" 2>/dev/null || true

    if [[ ${hook_exit} -eq 124 ]]; then
      local timeout_reason="wrapped hook timeout after ${hook_timeout_seconds:-?}s"
      codex_hook_status "${hook_name}" "${event_name}" "${hook_matcher}" "timeout" "${timeout_reason}" "${hook_detail}" "${hook_timeout_ms}"
      codex_diag "${hook_name}" "${event_name}" "wrapped-hook-timeout" "${timeout_reason}"
      rm -f "${normalized_file}" 2>/dev/null || true
      codex_visible_failure_raw "${event_name}" "VIBEGUARD hook timed out after ${hook_timeout_seconds:-?}s."
      return 0
    fi

    if [[ ${hook_exit} -ne 0 ]]; then
      codex_diag "${hook_name}" "${event_name}" "wrapped-hook-nonzero" "${hook_err:-${hook_output}}"
      rm -f "${normalized_file}" 2>/dev/null || true
      codex_visible_failure_raw "${event_name}" "VIBEGUARD hook failed: wrapped hook exited nonzero."
      return 0
    fi

    if [[ -z "${hook_output}" ]]; then
      codex_hook_status "${hook_name}" "${event_name}" "${hook_matcher}" "pass" "" "${hook_detail}" "${hook_timeout_ms}"
      continue
    fi
    if [[ "${VIBEGUARD_POLICY_ENFORCEMENT:-}" == "warn" ]] && declare -F vg_policy_downgrade_output >/dev/null 2>&1; then
      hook_output="$(vg_policy_downgrade_output "${hook_output}")"
    fi
    codex_hook_status_from_output "${hook_name}" "${event_name}" "${hook_matcher}" "${hook_output}" "${hook_detail}" "${hook_timeout_ms}"

    if [[ "${event_name}" == "PreToolUse" ]]; then
      pretool_status=0
      pretool_output=$(codex_adapt_pretool "${hook_output}") || pretool_status=$?
      if [[ ${pretool_status} -ne 0 ]]; then
        rm -f "${normalized_file}" 2>/dev/null || true
        if [[ -n "${pretool_output}" ]]; then
          printf '%s\n' "${pretool_output}"
        else
          codex_pretool_deny "VIBEGUARD hook failed: wrapped hook output could not be adapted."
        fi
        return 0
      fi
      if [[ -n "${pretool_output}" ]]; then
        if [[ "${pretool_output}" == *'"permissionDecision": "deny"'* || "${pretool_output}" == *'"permissionDecision":"deny"'* ]]; then
          rm -f "${normalized_file}" 2>/dev/null || true
          printf '%s\n' "${pretool_output}"
          return 0
        fi
        [[ -n "${first_adapted_output}" ]] || first_adapted_output="${pretool_output}"
      fi
    elif [[ "${event_name}" == "PermissionRequest" ]]; then
      permission_status=0
      permission_output=$(codex_adapt_permission_request "${hook_output}") || permission_status=$?
      if [[ ${permission_status} -ne 0 ]]; then
        rm -f "${normalized_file}" 2>/dev/null || true
        if [[ -n "${permission_output}" ]]; then
          printf '%s\n' "${permission_output}"
        else
          codex_permission_deny "VIBEGUARD hook failed: wrapped hook output could not be adapted."
        fi
        return 0
      fi
      if [[ -n "${permission_output}" ]]; then
        if [[ "${permission_output}" == *'"behavior": "deny"'* || "${permission_output}" == *'"behavior":"deny"'* ]]; then
          rm -f "${normalized_file}" 2>/dev/null || true
          printf '%s\n' "${permission_output}"
          return 0
        fi
        [[ -n "${first_adapted_output}" ]] || first_adapted_output="${permission_output}"
      fi
    elif [[ "${event_name}" == "PostToolUse" ]]; then
      posttool_status=0
      posttool_output=$(codex_adapt_posttool "${hook_output}" 2>/dev/null) || posttool_status=$?
      if [[ ${posttool_status} -ne 0 ]]; then
        codex_diag "${hook_name}" "${event_name}" "posttool-adapter-failed" "${hook_output}"
        rm -f "${normalized_file}" 2>/dev/null || true
        codex_visible_failure_raw "${event_name}" "VIBEGUARD hook failed: wrapped PostToolUse output could not be adapted."
        return 0
      fi
      if [[ -n "${posttool_output}" ]]; then
        if [[ "${posttool_output}" == *'"decision": "block"'* || "${posttool_output}" == *'"decision":"block"'* ]]; then
          rm -f "${normalized_file}" 2>/dev/null || true
          printf '%s\n' "${posttool_output}"
          return 0
        fi
        [[ -n "${first_adapted_output}" ]] || first_adapted_output="${posttool_output}"
      fi
    else
      [[ -n "${first_adapted_output}" ]] || first_adapted_output="${hook_output}"
    fi
  done <"${normalized_file}"

  rm -f "${normalized_file}" 2>/dev/null || true
  [[ -z "${first_adapted_output}" ]] || printf '%s\n' "${first_adapted_output}"
}

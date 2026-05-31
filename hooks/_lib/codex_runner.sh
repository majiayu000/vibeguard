#!/usr/bin/env bash
# Codex wrapper execution loop. Keep run-hook-codex.sh as a thin dispatcher.

codex_run_hook() {
  local hook_name="$1" hook_path="$2" normalizer_path="$3" input="$4"
  shift 4

  export PYTHONUTF8=1 PYTHONIOENCODING=utf-8

  local normalized_file
  normalized_file="$(mktemp "${TMPDIR:-/tmp}/vibeguard-codex-inputs.XXXXXX")"
  if [[ -f "${normalizer_path}" ]]; then
    if ! printf '%s' "${input}" | python3 "${normalizer_path}" "${hook_name}" >"${normalized_file}"; then
      codex_diag "${hook_name}" "${EVENT_NAME}" "normalizer-failed" "${normalizer_path}"
      printf '%s\n' "${input}" >"${normalized_file}"
    fi
  else
    printf '%s\n' "${input}" >"${normalized_file}"
  fi

  local first_adapted_output=""
  local normalized_input hook_output hook_exit hook_err_file hook_err event_name
  local pretool_status pretool_output permission_status permission_output
  local posttool_status posttool_output
  while IFS= read -r normalized_input || [[ -n "${normalized_input:-}" ]]; do
    [[ -n "${normalized_input}" ]] || continue

    hook_output=""
    hook_exit=0
    hook_err_file="$(mktemp "${TMPDIR:-/tmp}/vibeguard-codex-hook.XXXXXX")"
    hook_output=$(printf '%s' "${normalized_input}" | bash "${hook_path}" "$@" 2>"${hook_err_file}") || hook_exit=$?
    hook_err="$(cat "${hook_err_file}" 2>/dev/null || true)"
    rm -f "${hook_err_file}" 2>/dev/null || true
    event_name=$(codex_event_name "${normalized_input}")

    if [[ ${hook_exit} -ne 0 ]]; then
      codex_diag "${hook_name}" "${event_name}" "wrapped-hook-nonzero" "${hook_err:-${hook_output}}"
      rm -f "${normalized_file}" 2>/dev/null || true
      codex_visible_failure_raw "${event_name}" "VIBEGUARD hook failed: wrapped hook exited nonzero."
      return 0
    fi

    [[ -n "${hook_output}" ]] || continue
    if [[ "${VIBEGUARD_POLICY_ENFORCEMENT:-}" == "warn" ]] && declare -F vg_policy_downgrade_output >/dev/null 2>&1; then
      hook_output="$(vg_policy_downgrade_output "${hook_output}")"
    fi

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

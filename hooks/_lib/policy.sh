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

vg_policy_runtime_supports_cwd_json() {
  local candidate="$1" probe_dir probe_output decision probe_cwd
  probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/vibeguard-policy-probe-cwd.XXXXXX")" || return 1
  probe_output="$(
    VIBEGUARD_PROJECT_CONFIG="" \
      VIBEGUARD_USER_CONFIG_FILE="" \
      "${candidate}" runtime-policy-check --cwd "${probe_dir}" __vibeguard_policy_probe__ 2>/dev/null
  )" || {
    rm -rf "${probe_dir}" 2>/dev/null || true
    return 1
  }
  decision="$(printf '%s' "${probe_output}" | "${candidate}" json-field --strict decision 2>/dev/null)" || {
    rm -rf "${probe_dir}" 2>/dev/null || true
    return 1
  }
  probe_cwd="$(printf '%s' "${probe_output}" | "${candidate}" json-field --strict cwd 2>/dev/null)" || {
    rm -rf "${probe_dir}" 2>/dev/null || true
    return 1
  }
  rm -rf "${probe_dir}" 2>/dev/null || true
  [[ "${decision}" == "run" && "${probe_cwd}" == "${probe_dir}" ]]
}

vg_policy_runtime_supports() {
  local candidate="$1" probe_diag downgrade_probe codex_probe
  if ! "${candidate}" runtime-policy-supports >/dev/null 2>&1; then
    return 1
  fi
  vg_policy_runtime_supports_cwd_json "${candidate}" || return 1
  probe_diag="${TMPDIR:-/tmp}/vibeguard-policy-probe.$$.jsonl"
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

vg_policy_json_field() {
  local runtime_path="$1" json_input="$2" field="$3" mode="${4:-}"
  if [[ "${mode}" == "strict" ]]; then
    printf '%s' "${json_input}" | "${runtime_path}" json-field --strict "${field}" 2>/dev/null
  else
    printf '%s' "${json_input}" | "${runtime_path}" json-field "${field}" 2>/dev/null
  fi
}

vg_policy_payload_cwd() {
  local payload_ref="$1" runtime_path="$2" field value
  [[ -n "${payload_ref}" ]] || return 1
  for field in cwd params.cwd workspace.cwd workspace.current_dir; do
    if [[ -f "${payload_ref}" ]]; then
      value="$("${runtime_path}" json-field "${field}" < "${payload_ref}" 2>/dev/null || true)"
    else
      value="$(printf '%s' "${payload_ref}" | "${runtime_path}" json-field "${field}" 2>/dev/null || true)"
    fi
    if [[ -n "${value}" && "${value}" != "null" && "${value}" != \{* && "${value}" != \[* ]]; then
      printf '%s\n' "${value}"
      return 0
    fi
  done
  return 1
}

vg_policy_git_root() {
  # PERF-OK: policy checks need the current repo root; failures fall back upstream.
  git rev-parse --show-toplevel 2>/dev/null || true
}

vg_policy_resolve_cwd() {
  local payload_ref="${1:-}" runtime_path="${2:-}" candidate
  for candidate in "${VIBEGUARD_POLICY_CWD:-}" "${VIBEGUARD_PROJECT_ROOT:-}" "${VIBEGUARD_PROJECT_CWD:-}"; do
    if [[ -n "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  if [[ -n "${runtime_path}" ]] && candidate="$(vg_policy_payload_cwd "${payload_ref}" "${runtime_path}")" && [[ -n "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
    return 0
  fi
  pwd -P 2>/dev/null || pwd
}

vg_policy_check_hook() {
  local hook_name="$1"
  local payload_ref="${2:-}"
  local output stderr_output status runtime_path policy_cwd decision enforcement reason output_filter
  local stdout_file stderr_file

  VG_POLICY_REASON=""
  VG_POLICY_KIND=""
  VG_POLICY_ENFORCEMENT="block"
  VG_POLICY_OUTPUT_FILTER=0
  VG_POLICY_RUNTIME_PATH=""
  VG_POLICY_CWD=""
  VG_POLICY_HOOK_NAME="${hook_name}"
  export VIBEGUARD_POLICY_ENFORCEMENT="block"
  export VG_POLICY_OUTPUT_FILTER=0

  if ! runtime_path="$(vg_policy_runtime_path)"; then
    VG_POLICY_REASON="VibeGuard policy error: vibeguard-runtime is required for runtime policy checks."
    VG_POLICY_KIND="policy_error"
    return 20
  fi
  VG_POLICY_RUNTIME_PATH="${runtime_path}"
  policy_cwd="$(vg_policy_resolve_cwd "${payload_ref}" "${runtime_path}")"
  VG_POLICY_CWD="${policy_cwd}"

  stdout_file="$(mktemp "${TMPDIR:-/tmp}/vibeguard-policy-stdout.XXXXXX")" || {
    VG_POLICY_REASON="VibeGuard policy error: failed to allocate runtime policy stdout capture."
    VG_POLICY_KIND="policy_error"
    return 20
  }
  stderr_file="$(mktemp "${TMPDIR:-/tmp}/vibeguard-policy-stderr.XXXXXX")" || {
    rm -f "${stdout_file}" 2>/dev/null || true
    VG_POLICY_REASON="VibeGuard policy error: failed to allocate runtime policy stderr capture."
    VG_POLICY_KIND="policy_error"
    return 20
  }

  local -a check_args
  check_args=(runtime-policy-check)
  if [[ -n "${policy_cwd}" ]]; then
    check_args+=(--cwd "${policy_cwd}")
  fi
  check_args+=("${hook_name}")
  status=0
  VIBEGUARD_USER_CONFIG_FILE="$(vg_policy_user_config_file)" \
    "${runtime_path}" "${check_args[@]}" >"${stdout_file}" 2>"${stderr_file}" || status=$?
  output="$(cat "${stdout_file}")"
  stderr_output="$(cat "${stderr_file}")"
  rm -f "${stdout_file}" "${stderr_file}" 2>/dev/null || true

  if ! decision="$(vg_policy_json_field "${runtime_path}" "${output}" "decision" "strict")"; then
    VG_POLICY_REASON="${stderr_output:-${output:-VibeGuard policy error: runtime-policy-check did not return policy JSON.}}"
    VG_POLICY_KIND="policy_error"
    return 20
  fi
  enforcement="$(vg_policy_json_field "${runtime_path}" "${output}" "enforcement" || true)"
  output_filter="$(vg_policy_json_field "${runtime_path}" "${output}" "output_filter" || true)"
  reason="$(vg_policy_json_field "${runtime_path}" "${output}" "reason" || true)"

  case "${status}" in
    0)
      if [[ "${decision}" != "run" ]]; then
        VG_POLICY_REASON="${reason:-VibeGuard policy error: runtime-policy-check returned decision=${decision} with allow exit.}"
        VG_POLICY_KIND="policy_error"
        return 20
      fi
      if [[ "${enforcement}" == "warn" ]]; then
        VG_POLICY_REASON="${reason}"
        VG_POLICY_KIND="policy_warn"
        VG_POLICY_ENFORCEMENT="warn"
        export VIBEGUARD_POLICY_ENFORCEMENT="warn"
      fi
      if [[ "${output_filter}" == "true" ]]; then
        VG_POLICY_OUTPUT_FILTER=1
        export VG_POLICY_OUTPUT_FILTER=1
      fi
      return 0
      ;;
    10)
      if [[ "${decision}" != "skip" ]]; then
        VG_POLICY_REASON="${reason:-VibeGuard policy error: runtime-policy-check returned decision=${decision} with skip exit.}"
        VG_POLICY_KIND="policy_error"
        return 20
      fi
      VG_POLICY_REASON="${reason:-${stderr_output:-${output}}}"
      VG_POLICY_KIND="policy_skip"
      return 10
      ;;
    30)
      VG_POLICY_REASON="${reason:-${stderr_output:-${output}}}"
      VG_POLICY_KIND="config_parse_error"
      return 30
      ;;
    *)
      VG_POLICY_REASON="${reason:-${stderr_output:-${output:-VibeGuard policy error: unknown runtime policy failure.}}}"
      VG_POLICY_KIND="policy_error"
      return 20
      ;;
  esac
}

vg_policy_downgrade_output() {
  local output="$1" hook_name="${2:-${VG_POLICY_HOOK_NAME:-}}" runtime_path
  if [[ -z "${output}" ]]; then
    printf '%s\n' "${output}"
    return 0
  fi
  if [[ "${VIBEGUARD_POLICY_ENFORCEMENT:-}" != "warn" && "${VG_POLICY_OUTPUT_FILTER:-0}" != "1" ]]; then
    printf '%s\n' "${output}"
    return 0
  fi

  runtime_path="${VG_POLICY_RUNTIME_PATH:-}"
  if [[ -z "${runtime_path}" ]] && ! runtime_path="$(vg_policy_runtime_path)"; then
    printf 'VibeGuard policy error: vibeguard-runtime is required for warn-mode output downgrade.\n' >&2
    printf '%s\n' "${output}"
    return 0
  fi

  local -a downgrade_args
  downgrade_args=(runtime-policy-downgrade-output)
  if [[ "${VIBEGUARD_POLICY_ENFORCEMENT:-}" == "warn" ]]; then
    downgrade_args+=(--warn-mode)
  fi
  if [[ -n "${VG_POLICY_CWD:-}" ]]; then
    downgrade_args+=(--cwd "${VG_POLICY_CWD}")
  fi
  if [[ -n "${hook_name}" ]]; then
    downgrade_args+=("${hook_name}")
  fi

  printf '%s' "${output}" | "${runtime_path}" "${downgrade_args[@]}" || {
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
  local hook_name="$1" event_name="$2" payload_file="${3:-}" policy_status=0
  vg_policy_check_hook "${hook_name}" "${payload_file}" || policy_status=$?
  [[ ${policy_status} -eq 0 ]] && return 0

  vg_policy_diag "${hook_name}" "${event_name}" "${VG_POLICY_KIND}" "${VG_POLICY_REASON}"
  if declare -F codex_diag >/dev/null 2>&1; then
    codex_diag "${hook_name}" "${event_name}" "${VG_POLICY_KIND}" "${VG_POLICY_REASON}"
  fi
  [[ ${policy_status} -eq 10 ]] && return 1
  vg_policy_codex_error_output "${event_name}" "${VG_POLICY_REASON}"
  return 1
}

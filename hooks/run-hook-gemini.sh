#!/usr/bin/env bash
# VibeGuard Gemini CLI BeforeTool adapter.
set -euo pipefail

wrapper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
runtime="${wrapper_dir}/installed/bin/vibeguard-runtime"
run_hook="${wrapper_dir}/run-hook.sh"
timeout_helper="${wrapper_dir}/installed/hooks/_lib/timeout.sh"
hook_timeout_seconds="5"
if [[ $# -eq 6 && "$1" == "--test-only" ]]; then
  runtime="$2"
  run_hook="$3"
  timeout_helper="$4"
  export VIBEGUARD_EXECUTION_MODE="$5"
  hook_timeout_seconds="$6"
elif [[ $# -ne 0 ]]; then
  printf '%s\n' '{"decision":"deny","reason":"VIBEGUARD Gemini adapter received invalid wrapper arguments; the tool call was denied."}'
  exit 0
else
  export HOME="$(cd "${wrapper_dir}/.." && pwd -P)"
  export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
  export VIBEGUARD_EXECUTION_MODE="installed-snapshot"
  unset BASH_ENV ENV VIBEGUARD_RUNTIME VIBEGUARD_POLICY_RUNTIME
  unset VG_POLICY_RUNTIME_PATH_CACHE VG_WRAPPER_ENV_RUNTIME_PATH_CACHE VIBEGUARD_HOOK_DIR
  unset VIBEGUARD_CONFIG_FILE VIBEGUARD_USER_CONFIG_FILE VIBEGUARD_PROJECT_CONFIG
  unset VIBEGUARD_POLICY_CWD VIBEGUARD_PROJECT_ROOT VIBEGUARD_PROJECT_CWD VIBEGUARD_LOG_DIR
fi

export VIBEGUARD_CLI="gemini"
export VIBEGUARD_CLIENT="gemini"
export VIBEGUARD_CLIENT_VARIANT="gemini-cli-hooks"
export VIBEGUARD_WRAPPER="run-hook-gemini.sh"
export VIBEGUARD_SOURCE_CONFIG="${GEMINI_CLI_HOME:-${HOME}}/.gemini/settings.json"
export VIBEGUARD_HOOK_PROTOCOL_VERSION="gemini-cli-hooks-v1"
export VIBEGUARD_CALLER_EVIDENCE="gemini-settings-before-tool"

fallback_deny() {
  printf '%s\n' '{"decision":"deny","reason":"VIBEGUARD Gemini adapter is unavailable; the tool call was denied. Re-run VibeGuard setup with --host gemini."}'
}

deny() {
  local reason="$1"
  if [[ -x "${runtime}" ]] \
    && printf '%s' "${reason}" | vg_run_with_timeout 2 "${runtime}" gemini-deny 2>/dev/null; then
    return 0
  fi
  fallback_deny
}

if [[ ! -f "${timeout_helper}" ]]; then
  fallback_deny
  exit 0
fi
# shellcheck source=hooks/_lib/timeout.sh
source "${timeout_helper}"
if ! declare -F vg_run_with_timeout >/dev/null 2>&1 \
  || [[ ! -x "${runtime}" || ! -f "${run_hook}" ]]; then
  fallback_deny
  exit 0
fi

input="$(vg_run_with_timeout 2 cat)" || {
  deny "VIBEGUARD Gemini adapter could not read the BeforeTool payload; the tool call was denied."
  exit 0
}

if ! hook_script="$(printf '%s' "${input}" | vg_run_with_timeout 2 "${runtime}" gemini-route-before-tool 2>/dev/null)"; then
  deny "VIBEGUARD Gemini adapter received a malformed or unsupported BeforeTool payload; the tool call was denied."
  exit 0
fi

session_id="$(printf '%s' "${input}" | vg_run_with_timeout 2 "${runtime}" json-field session_id 2>/dev/null || true)"
if [[ -n "${session_id}" ]]; then
  export VIBEGUARD_SESSION_ID="${session_id}"
  export VIBEGUARD_SESSION_SOURCE="gemini-before-tool"
fi

guard_output=""
if ! guard_output="$(printf '%s' "${input}" | vg_run_with_timeout "${hook_timeout_seconds}" bash "${run_hook}" "${hook_script}")"; then
  deny "VIBEGUARD Gemini adapter could not execute the policy hook; the tool call was denied."
  exit 0
fi

if ! printf '%s' "${guard_output}" | vg_run_with_timeout 2 "${runtime}" gemini-adapt-before-tool; then
  deny "VIBEGUARD Gemini adapter could not encode the policy result; the tool call was denied."
fi

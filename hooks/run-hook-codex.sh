#!/usr/bin/env bash
# VibeGuard Codex Hook Wrapper: adapt Claude-style hook output to Codex.

set -euo pipefail

WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_NAME="${1:?Usage: run-hook-codex.sh <hook-name>}"
shift

INSTALLED_DIR="${HOME}/.vibeguard/installed/hooks"
REPO_PATH_FILE="${HOME}/.vibeguard/repo-path"
EXECUTION_MODE_FILE="${HOME}/.vibeguard/execution-mode"

vibeguard_execution_mode() {
  local mode="${VIBEGUARD_EXECUTION_MODE:-}"
  [[ -n "${mode}" || ! -f "${EXECUTION_MODE_FILE}" ]] || mode="$(tr -d '[:space:]' < "${EXECUTION_MODE_FILE}")"
  case "${mode}" in
    dev-linked|dev-linked-repo|repo|repo-linked) printf '%s\n' "dev-linked-repo" ;;
    *) printf '%s\n' "installed-snapshot" ;;
  esac
}

EXECUTION_MODE="$(vibeguard_execution_mode)"
REPO_DIR=""
[[ "${EXECUTION_MODE}" != "dev-linked-repo" || ! -f "${REPO_PATH_FILE}" ]] || REPO_DIR=$(<"${REPO_PATH_FILE}")

helper_path() {
  local helper="$1" override="${2:-}"
  [[ -z "${override}" ]] || { printf '%s\n' "${override}"; return; }
  if [[ "${EXECUTION_MODE}" == "dev-linked-repo" && -n "${REPO_DIR}" && -f "${REPO_DIR}/hooks/_lib/${helper}" ]]; then
    printf '%s\n' "${REPO_DIR}/hooks/_lib/${helper}"
  elif [[ "${EXECUTION_MODE}" == "installed-snapshot" && -f "${INSTALLED_DIR}/_lib/${helper}" ]]; then
    printf '%s\n' "${INSTALLED_DIR}/_lib/${helper}"
  else
    printf '%s\n' "${WRAPPER_DIR}/_lib/${helper}"
  fi
}
DIAG_PATH="$(helper_path codex_diag.sh)"

if [[ -f "${DIAG_PATH}" ]]; then
  # shellcheck source=hooks/_lib/codex_diag.sh
  source "${DIAG_PATH}"
  if ! declare -F codex_permission_deny_raw >/dev/null 2>&1; then
    codex_permission_deny_raw() { printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"VIBEGUARD install incomplete."}}}\n'; }
  fi
else
  codex_raw_event_name() { [[ "$1" =~ \"hook_event_name\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && printf '%s\n' "${BASH_REMATCH[1]}"; }
  codex_pretool_deny_raw() { printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"VIBEGUARD install incomplete."}}\n'; }
  codex_permission_deny_raw() { printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"VIBEGUARD install incomplete."}}}\n'; }
  codex_visible_failure_raw() {
    [[ "$1" == "PreToolUse" ]] && { codex_pretool_deny_raw "$2"; return; }
    [[ "$1" == "PermissionRequest" ]] && { codex_permission_deny_raw "$2"; return; }
    [[ "$1" == "Stop" ]] && { printf '{"stopReason":"VIBEGUARD install incomplete."}\n'; return; }
    printf '{"systemMessage":"VIBEGUARD install incomplete."}\n'
  }
  codex_set_caller_identity() { export VIBEGUARD_CLIENT="${VIBEGUARD_CLIENT:-unknown}" VIBEGUARD_CLIENT_VARIANT="${VIBEGUARD_CLIENT_VARIANT:-unknown}" VIBEGUARD_CALLER_EVIDENCE="${VIBEGUARD_CALLER_EVIDENCE:-missing-codex-diag-helper}"; }
  codex_diag() { return 0; }
  codex_hook_timeout_ms() { printf '%s\n' ""; }
  codex_hook_status_detail() { printf '%s\n' ""; }
  codex_hook_status_matcher() { printf '%s\n' ""; }
  codex_hook_status() { return 0; }
  codex_hook_status_from_output() { return 0; }
fi
if ! declare -F codex_hook_status_from_output >/dev/null 2>&1; then
  codex_hook_status_from_output() { return 0; }
fi

INPUT=$(cat)
EVENT_NAME=$(codex_raw_event_name "$INPUT")
codex_set_caller_identity "${EVENT_NAME}"

if [[ "${HOOK_NAME}" != vibeguard-* ]]; then
  codex_diag "${HOOK_NAME}" "${EVENT_NAME}" "non-namespaced-hook" "${HOOK_NAME}"
  exit 0
fi

ADAPTER_PATH="$(helper_path codex_adapter.sh "${VIBEGUARD_CODEX_ADAPTER_PATH:-}")" # hooks/_lib/codex_adapter.sh
RUNNER_PATH="$(helper_path codex_runner.sh)"
TIMEOUT_PATH="$(helper_path timeout.sh)"

if [[ "${EXECUTION_MODE}" == "dev-linked-repo" ]]; then
  if [[ -z "${REPO_DIR}" ]]; then
    codex_diag "${HOOK_NAME}" "${EVENT_NAME}" "missing-repo-path" "${REPO_PATH_FILE}"
    codex_visible_failure_raw "${EVENT_NAME}" "VIBEGUARD install incomplete: missing repo-path."
    exit 0
  fi
  HOOK_PATH="${REPO_DIR}/hooks/${HOOK_NAME}"
else
  HOOK_PATH="${INSTALLED_DIR}/${HOOK_NAME}"
  if [[ ! -d "$INSTALLED_DIR" ]]; then
    codex_diag "${HOOK_NAME}" "${EVENT_NAME}" "missing-installed-snapshot" "${INSTALLED_DIR}"
    codex_visible_failure_raw "${EVENT_NAME}" "VIBEGUARD install incomplete: missing installed hook snapshot."
    exit 0
  fi
fi

WRAPPER_ENV_PATH="$(helper_path wrapper_env.sh)"
[[ ! -f "${WRAPPER_ENV_PATH}" ]] || { source "${WRAPPER_ENV_PATH}"; vg_wrapper_env_export "codex"; }

POLICY_PATH="$(helper_path policy.sh)"
if [[ ! -f "${POLICY_PATH}" ]]; then
  codex_diag "${HOOK_NAME}" "${EVENT_NAME}" "policy_error" "missing policy helper"
  codex_visible_failure_raw "${EVENT_NAME}" "VIBEGUARD install incomplete: missing policy helper."
  exit 0
fi
# shellcheck source=hooks/_lib/policy.sh
source "${POLICY_PATH}"
vg_policy_codex_gate "${HOOK_NAME}" "${EVENT_NAME}" || exit 0

if [[ ! -f "$HOOK_PATH" ]]; then
  codex_diag "${HOOK_NAME}" "${EVENT_NAME}" "missing-hook" "${HOOK_PATH}"
  codex_visible_failure_raw "${EVENT_NAME}" "VIBEGUARD install incomplete: missing hook ${HOOK_NAME}."
  exit 0
fi

if [[ ! -f "${ADAPTER_PATH}" ]]; then
  codex_diag "${HOOK_NAME}" "${EVENT_NAME}" "missing-adapter" "${ADAPTER_PATH}"
  codex_visible_failure_raw "${EVENT_NAME}" "VIBEGUARD install incomplete: missing Codex adapter."
  exit 0
fi

source "${ADAPTER_PATH}"
# Adapter delegates: codex_event_name codex_pretool_deny codex_adapt_pretool codex_adapt_posttool.
if ! declare -F codex_permission_deny >/dev/null 2>&1; then codex_permission_deny() { codex_permission_deny_raw "$1"; }; fi
if ! declare -F codex_adapt_permission_request >/dev/null 2>&1; then codex_adapt_permission_request() { codex_permission_deny "VIBEGUARD install incomplete: missing PermissionRequest adapter."; }; fi

if [[ -f "${TIMEOUT_PATH}" ]]; then
  # shellcheck source=hooks/_lib/timeout.sh
  source "${TIMEOUT_PATH}"
fi

if [[ ! -f "${RUNNER_PATH}" ]]; then
  codex_diag "${HOOK_NAME}" "${EVENT_NAME}" "missing-runner" "${RUNNER_PATH}"
  codex_visible_failure_raw "${EVENT_NAME}" "VIBEGUARD install incomplete: missing Codex runner."
  exit 0
fi

source "${RUNNER_PATH}"
codex_run_hook "${HOOK_NAME}" "${HOOK_PATH}" "${INPUT}" "$@"
exit 0

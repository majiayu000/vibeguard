#!/usr/bin/env bash
# VibeGuard Codex Hook Wrapper: adapt Claude-style hook output to Codex.

set -euo pipefail

WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_NAME="${1:?Usage: run-hook-codex.sh <hook-name>}"
shift

INSTALLED_DIR="${HOME}/.vibeguard/installed/hooks"
DIAG_PATH="${WRAPPER_DIR}/_lib/codex_diag.sh"
if [[ ! -f "${DIAG_PATH}" && -f "${INSTALLED_DIR}/_lib/codex_diag.sh" ]]; then
  DIAG_PATH="${INSTALLED_DIR}/_lib/codex_diag.sh"
fi
if [[ ! -f "${DIAG_PATH}" ]]; then
  REPO_PATH_FILE="${HOME}/.vibeguard/repo-path"
  if [[ -f "${REPO_PATH_FILE}" ]]; then
    REPO_DIR=$(<"${REPO_PATH_FILE}")
    if [[ -f "${REPO_DIR}/hooks/_lib/codex_diag.sh" ]]; then
      DIAG_PATH="${REPO_DIR}/hooks/_lib/codex_diag.sh"
    fi
  fi
fi

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
  codex_set_caller_identity() { export VIBEGUARD_CLIENT="${VIBEGUARD_CLIENT:-unknown}" VIBEGUARD_CLIENT_VARIANT="${VIBEGUARD_CLIENT_VARIANT:-unknown}" VIBEGUARD_CALLER_EVIDENCE="${VIBEGUARD_CALLER_EVIDENCE:-missing-codex-diag-helper}"; }
  codex_diag() { return 0; }
fi

INPUT=$(cat)
EVENT_NAME=$(codex_raw_event_name "$INPUT")
codex_set_caller_identity "${EVENT_NAME}"

if [[ "${HOOK_NAME}" != vibeguard-* ]]; then
  codex_diag "${HOOK_NAME}" "${EVENT_NAME}" "non-namespaced-hook" "${HOOK_NAME}"
  exit 0
fi

HOOK_PATH="${INSTALLED_DIR}/${HOOK_NAME}"
if [[ -n "${VIBEGUARD_CODEX_ADAPTER_PATH:-}" ]]; then
  ADAPTER_PATH="${VIBEGUARD_CODEX_ADAPTER_PATH}"
else
  ADAPTER_PATH="${WRAPPER_DIR}/_lib/codex_adapter.sh"
  if [[ ! -f "${ADAPTER_PATH}" && -f "${INSTALLED_DIR}/_lib/codex_adapter.sh" ]]; then
    ADAPTER_PATH="${INSTALLED_DIR}/_lib/codex_adapter.sh"
  fi
fi

RUNNER_PATH="${WRAPPER_DIR}/_lib/codex_runner.sh"
[[ -f "${RUNNER_PATH}" || ! -f "${INSTALLED_DIR}/_lib/codex_runner.sh" ]] || RUNNER_PATH="${INSTALLED_DIR}/_lib/codex_runner.sh"

NORMALIZER_PATH="${WRAPPER_DIR}/_lib/codex_apply_patch_adapter.py"
[[ -f "${NORMALIZER_PATH}" || ! -f "${INSTALLED_DIR}/_lib/codex_apply_patch_adapter.py" ]] || NORMALIZER_PATH="${INSTALLED_DIR}/_lib/codex_apply_patch_adapter.py"

if [[ ! -d "$INSTALLED_DIR" ]]; then
  REPO_PATH_FILE="${HOME}/.vibeguard/repo-path"
  if [[ ! -f "$REPO_PATH_FILE" ]]; then
    codex_diag "${HOOK_NAME}" "${EVENT_NAME}" "missing-repo-path" "${REPO_PATH_FILE}"
    if [[ "$EVENT_NAME" == "PreToolUse" ]]; then
      codex_pretool_deny_raw "VIBEGUARD install incomplete: missing repo-path."
    elif [[ "$EVENT_NAME" == "PermissionRequest" ]]; then
      codex_permission_deny_raw "VIBEGUARD install incomplete: missing repo-path."
    fi
    exit 0
  fi
  REPO_DIR=$(<"$REPO_PATH_FILE")
  HOOK_PATH="${REPO_DIR}/hooks/${HOOK_NAME}"
  if [[ -z "${VIBEGUARD_CODEX_ADAPTER_PATH:-}" && ! -f "${ADAPTER_PATH}" && -f "${REPO_DIR}/hooks/_lib/codex_adapter.sh" ]]; then
    ADAPTER_PATH="${REPO_DIR}/hooks/_lib/codex_adapter.sh"
  fi
  if [[ ! -f "${RUNNER_PATH}" && -f "${REPO_DIR}/hooks/_lib/codex_runner.sh" ]]; then
    RUNNER_PATH="${REPO_DIR}/hooks/_lib/codex_runner.sh"
  fi
  if [[ ! -f "${NORMALIZER_PATH}" && -f "${REPO_DIR}/hooks/_lib/codex_apply_patch_adapter.py" ]]; then
    NORMALIZER_PATH="${REPO_DIR}/hooks/_lib/codex_apply_patch_adapter.py"
  fi
fi

POLICY_PATH="${WRAPPER_DIR}/_lib/policy.sh"
[[ -f "${POLICY_PATH}" ]] || POLICY_PATH="${INSTALLED_DIR}/_lib/policy.sh"
[[ -f "${POLICY_PATH}" ]] || POLICY_PATH="$(dirname "${HOOK_PATH}")/_lib/policy.sh"
if [[ ! -f "${POLICY_PATH}" ]]; then
  codex_diag "${HOOK_NAME}" "${EVENT_NAME}" "policy_error" "missing policy helper"
  [[ "$EVENT_NAME" == "PreToolUse" ]] && codex_pretool_deny_raw "VIBEGUARD install incomplete: missing policy helper."
  [[ "$EVENT_NAME" == "PermissionRequest" ]] && codex_permission_deny_raw "VIBEGUARD install incomplete: missing policy helper."
  exit 0
fi
# shellcheck source=hooks/_lib/policy.sh
source "${POLICY_PATH}"
vg_policy_codex_gate "${HOOK_NAME}" "${EVENT_NAME}" || exit 0

if [[ ! -f "$HOOK_PATH" ]]; then
  codex_diag "${HOOK_NAME}" "${EVENT_NAME}" "missing-hook" "${HOOK_PATH}"
  if [[ "$EVENT_NAME" == "PreToolUse" ]]; then
    codex_pretool_deny_raw "VIBEGUARD install incomplete: missing hook ${HOOK_NAME}."
  elif [[ "$EVENT_NAME" == "PermissionRequest" ]]; then
    codex_permission_deny_raw "VIBEGUARD install incomplete: missing hook ${HOOK_NAME}."
  fi
  exit 0
fi

if [[ ! -f "${ADAPTER_PATH}" ]]; then
  codex_diag "${HOOK_NAME}" "${EVENT_NAME}" "missing-adapter" "${ADAPTER_PATH}"
  if [[ "$EVENT_NAME" == "PreToolUse" ]]; then
    codex_pretool_deny_raw "VIBEGUARD install incomplete: missing Codex adapter."
  elif [[ "$EVENT_NAME" == "PermissionRequest" ]]; then
    codex_permission_deny_raw "VIBEGUARD install incomplete: missing Codex adapter."
  fi
  exit 0
fi

source "${ADAPTER_PATH}"
# Adapter delegates: codex_event_name codex_pretool_deny codex_adapt_pretool codex_adapt_posttool.
if ! declare -F codex_permission_deny >/dev/null 2>&1; then codex_permission_deny() { codex_permission_deny_raw "$1"; }; fi
if ! declare -F codex_adapt_permission_request >/dev/null 2>&1; then codex_adapt_permission_request() { codex_permission_deny "VIBEGUARD install incomplete: missing PermissionRequest adapter."; }; fi

if [[ ! -f "${RUNNER_PATH}" ]]; then
  codex_diag "${HOOK_NAME}" "${EVENT_NAME}" "missing-runner" "${RUNNER_PATH}"
  [[ "${EVENT_NAME}" == "PreToolUse" ]] && codex_pretool_deny "VIBEGUARD install incomplete: missing Codex runner."
  [[ "${EVENT_NAME}" == "PermissionRequest" ]] && codex_permission_deny "VIBEGUARD install incomplete: missing Codex runner."
  exit 0
fi

source "${RUNNER_PATH}"
codex_run_hook "${HOOK_NAME}" "${HOOK_PATH}" "${NORMALIZER_PATH}" "${INPUT}" "$@"
exit 0

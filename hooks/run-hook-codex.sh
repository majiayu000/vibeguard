#!/usr/bin/env bash
# VibeGuard Codex Hook Wrapper: adapt Claude-style hook output to Codex.

set -euo pipefail

export VIBEGUARD_AGENT_TYPE="codex"
export VIBEGUARD_CLI="codex"

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
else
  codex_raw_event_name() { printf '\n'; }
  codex_pretool_deny_raw() { printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"VIBEGUARD install incomplete."}}\n'; }
  codex_diag() { return 0; }
fi

INPUT=$(cat)
EVENT_NAME=$(codex_raw_event_name "$INPUT")

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

if [[ ! -d "$INSTALLED_DIR" ]]; then
  REPO_PATH_FILE="${HOME}/.vibeguard/repo-path"
  if [[ ! -f "$REPO_PATH_FILE" ]]; then
    codex_diag "${HOOK_NAME}" "${EVENT_NAME}" "missing-repo-path" "${REPO_PATH_FILE}"
    if [[ "$EVENT_NAME" == "PreToolUse" ]]; then
      codex_pretool_deny_raw "VIBEGUARD install incomplete: missing repo-path."
    fi
    exit 0
  fi
  REPO_DIR=$(<"$REPO_PATH_FILE")
  HOOK_PATH="${REPO_DIR}/hooks/${HOOK_NAME}"
  if [[ -z "${VIBEGUARD_CODEX_ADAPTER_PATH:-}" && ! -f "${ADAPTER_PATH}" && -f "${REPO_DIR}/hooks/_lib/codex_adapter.sh" ]]; then
    ADAPTER_PATH="${REPO_DIR}/hooks/_lib/codex_adapter.sh"
  fi
fi

if [[ ! -f "$HOOK_PATH" ]]; then
  codex_diag "${HOOK_NAME}" "${EVENT_NAME}" "missing-hook" "${HOOK_PATH}"
  if [[ "$EVENT_NAME" == "PreToolUse" ]]; then
    codex_pretool_deny_raw "VIBEGUARD install incomplete: missing hook ${HOOK_NAME}."
  fi
  exit 0
fi

if [[ ! -f "${ADAPTER_PATH}" ]]; then
  codex_diag "${HOOK_NAME}" "${EVENT_NAME}" "missing-adapter" "${ADAPTER_PATH}"
  if [[ "$EVENT_NAME" == "PreToolUse" ]]; then
    codex_pretool_deny_raw "VIBEGUARD install incomplete: missing Codex adapter."
  fi
  exit 0
fi

source "${ADAPTER_PATH}"

export PYTHONUTF8=1 PYTHONIOENCODING=utf-8

HOOK_OUTPUT=""
HOOK_EXIT=0
HOOK_ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/vibeguard-codex-hook.XXXXXX")"
HOOK_OUTPUT=$(printf '%s' "$INPUT" | bash "$HOOK_PATH" "$@" 2>"${HOOK_ERR_FILE}") || HOOK_EXIT=$?
HOOK_ERR="$(cat "${HOOK_ERR_FILE}" 2>/dev/null || true)"
rm -f "${HOOK_ERR_FILE}" 2>/dev/null || true
EVENT_NAME=$(codex_event_name "$INPUT")

if [[ $HOOK_EXIT -ne 0 ]]; then
  codex_diag "${HOOK_NAME}" "${EVENT_NAME}" "wrapped-hook-nonzero" "${HOOK_ERR:-${HOOK_OUTPUT}}"
  if [[ "$EVENT_NAME" == "PreToolUse" ]]; then
    codex_pretool_deny "VIBEGUARD hook failed: wrapped hook exited nonzero."
    exit 0
  fi
  exit 0
fi

if [[ -z "$HOOK_OUTPUT" ]]; then
  exit 0
fi

if [[ "$EVENT_NAME" == "PreToolUse" ]]; then
  pretool_status=0
  pretool_output=$(codex_adapt_pretool "$HOOK_OUTPUT") || pretool_status=$?
  if [[ ${pretool_status} -ne 0 ]]; then
    if [[ -n "$pretool_output" ]]; then
      printf '%s\n' "$pretool_output"
    else
      codex_pretool_deny "VIBEGUARD hook failed: wrapped hook output could not be adapted."
    fi
    exit 0
  fi
  if [[ -n "$pretool_output" ]]; then
    printf '%s\n' "$pretool_output"
  fi
elif [[ "$EVENT_NAME" == "PostToolUse" ]]; then
  posttool_status=0
  posttool_output=$(codex_adapt_posttool "$HOOK_OUTPUT" 2>/dev/null) || posttool_status=$?
  if [[ ${posttool_status} -ne 0 ]]; then
    codex_diag "${HOOK_NAME}" "${EVENT_NAME}" "posttool-adapter-failed" "$HOOK_OUTPUT"
    exit 0
  fi
  if [[ -n "${posttool_output}" ]]; then
    printf '%s\n' "${posttool_output}"
  fi
else
  printf '%s\n' "$HOOK_OUTPUT"
fi

exit 0

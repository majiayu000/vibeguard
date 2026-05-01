#!/usr/bin/env bash
# VibeGuard Codex Hook Wrapper — Adapt the output format of Codex CLI
#
# The I/O formats of Codex CLI hooks and Claude Code hooks are different:
# - PreToolUse block: Codex requires hookSpecificOutput.permissionDecision="deny"
# - PreToolUse warn: Codex uses systemMessage
# - updatedInput (correction): Codex CLI cannot apply it directly, emit an explicit note instead
# - SessionStart/Stop: The format is basically compatible, direct transparent transmission
#
# Usage: bash run-hook-codex.sh <hook-script-name> [args...]

set -euo pipefail

export VIBEGUARD_AGENT_TYPE="codex"
export VIBEGUARD_CLI="codex"

WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_NAME="${1:?Usage: run-hook-codex.sh <hook-name>}"
shift

# Codex path is namespaced-only. Non-namespaced hook names are unsupported.
if [[ "${HOOK_NAME}" != vibeguard-* ]]; then
  exit 0
fi

INSTALLED_DIR="${HOME}/.vibeguard/installed/hooks"
HOOK_PATH="${INSTALLED_DIR}/${HOOK_NAME}"
ADAPTER_PATH="${WRAPPER_DIR}/_lib/codex_adapter.sh"
if [[ ! -f "${ADAPTER_PATH}" && -f "${INSTALLED_DIR}/_lib/codex_adapter.sh" ]]; then
  ADAPTER_PATH="${INSTALLED_DIR}/_lib/codex_adapter.sh"
fi

if [[ ! -d "$INSTALLED_DIR" ]]; then
  REPO_PATH_FILE="${HOME}/.vibeguard/repo-path"
  if [[ ! -f "$REPO_PATH_FILE" ]]; then
    exit 0
  fi
  REPO_DIR=$(<"$REPO_PATH_FILE")
  HOOK_PATH="${REPO_DIR}/hooks/${HOOK_NAME}"
  if [[ ! -f "${ADAPTER_PATH}" && -f "${REPO_DIR}/hooks/_lib/codex_adapter.sh" ]]; then
    ADAPTER_PATH="${REPO_DIR}/hooks/_lib/codex_adapter.sh"
  fi
fi

if [[ ! -f "$HOOK_PATH" ]]; then
  exit 0
fi

if [[ ! -f "${ADAPTER_PATH}" ]]; then
  exit 0
fi

# shellcheck source=hooks/_lib/codex_adapter.sh
source "${ADAPTER_PATH}"

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

INPUT=$(cat)

HOOK_OUTPUT=""
HOOK_EXIT=0
HOOK_OUTPUT=$(printf '%s' "$INPUT" | bash "$HOOK_PATH" "$@" 2>/dev/null) || HOOK_EXIT=$?

EVENT_NAME=$(codex_event_name "$INPUT")

if [[ $HOOK_EXIT -ne 0 ]]; then
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
  codex_adapt_posttool "$HOOK_OUTPUT" 2>/dev/null
else
  # SessionStart / Stop / UserPromptSubmit — direct transparent transmission
  printf '%s\n' "$HOOK_OUTPUT"
fi

exit 0

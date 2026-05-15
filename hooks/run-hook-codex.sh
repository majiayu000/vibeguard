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
  if ! declare -F codex_permission_deny_raw >/dev/null 2>&1; then
    codex_permission_deny_raw() { printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"VIBEGUARD install incomplete."}}}\n'; }
  fi
else
  codex_raw_event_name() { [[ "$1" =~ \"hook_event_name\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && printf '%s\n' "${BASH_REMATCH[1]}"; }
  codex_pretool_deny_raw() { printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"VIBEGUARD install incomplete."}}\n'; }
  codex_permission_deny_raw() { printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"VIBEGUARD install incomplete."}}}\n'; }
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

NORMALIZER_PATH="${WRAPPER_DIR}/_lib/codex_apply_patch_adapter.py"
if [[ ! -f "${NORMALIZER_PATH}" && -f "${INSTALLED_DIR}/_lib/codex_apply_patch_adapter.py" ]]; then
  NORMALIZER_PATH="${INSTALLED_DIR}/_lib/codex_apply_patch_adapter.py"
fi

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
  if [[ ! -f "${NORMALIZER_PATH}" && -f "${REPO_DIR}/hooks/_lib/codex_apply_patch_adapter.py" ]]; then
    NORMALIZER_PATH="${REPO_DIR}/hooks/_lib/codex_apply_patch_adapter.py"
  fi
fi

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
if ! declare -F codex_permission_deny >/dev/null 2>&1; then
  codex_permission_deny() {
    local reason="$1"
    CODEX_REASON="${reason}" python3 - <<'PY'
import json
import os

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PermissionRequest",
        "decision": {
            "behavior": "deny",
            "message": os.environ.get("CODEX_REASON", ""),
        },
    }
}, ensure_ascii=False))
PY
  }
fi
if ! declare -F codex_adapt_permission_request >/dev/null 2>&1; then
  codex_adapt_permission_request() {
    codex_permission_deny "VIBEGUARD install incomplete: missing PermissionRequest adapter."
  }
fi

export PYTHONUTF8=1 PYTHONIOENCODING=utf-8

NORMALIZED_FILE="$(mktemp "${TMPDIR:-/tmp}/vibeguard-codex-inputs.XXXXXX")"
if [[ -f "${NORMALIZER_PATH}" ]]; then
  if ! printf '%s' "$INPUT" | python3 "${NORMALIZER_PATH}" "${HOOK_NAME}" >"${NORMALIZED_FILE}"; then
    codex_diag "${HOOK_NAME}" "${EVENT_NAME}" "normalizer-failed" "${NORMALIZER_PATH}"
    printf '%s\n' "$INPUT" >"${NORMALIZED_FILE}"
  fi
else
  printf '%s\n' "$INPUT" >"${NORMALIZED_FILE}"
fi

FIRST_ADAPTED_OUTPUT=""
while IFS= read -r NORMALIZED_INPUT || [[ -n "${NORMALIZED_INPUT:-}" ]]; do
  [[ -n "${NORMALIZED_INPUT}" ]] || continue

  HOOK_OUTPUT=""
  HOOK_EXIT=0
  HOOK_ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/vibeguard-codex-hook.XXXXXX")"
  HOOK_OUTPUT=$(printf '%s' "$NORMALIZED_INPUT" | bash "$HOOK_PATH" "$@" 2>"${HOOK_ERR_FILE}") || HOOK_EXIT=$?
  HOOK_ERR="$(cat "${HOOK_ERR_FILE}" 2>/dev/null || true)"
  rm -f "${HOOK_ERR_FILE}" 2>/dev/null || true
  EVENT_NAME=$(codex_event_name "$NORMALIZED_INPUT")

  if [[ $HOOK_EXIT -ne 0 ]]; then
    codex_diag "${HOOK_NAME}" "${EVENT_NAME}" "wrapped-hook-nonzero" "${HOOK_ERR:-${HOOK_OUTPUT}}"
    if [[ "$EVENT_NAME" == "PreToolUse" ]]; then
      rm -f "${NORMALIZED_FILE}" 2>/dev/null || true
      codex_pretool_deny "VIBEGUARD hook failed: wrapped hook exited nonzero."
      exit 0
    elif [[ "$EVENT_NAME" == "PermissionRequest" ]]; then
      rm -f "${NORMALIZED_FILE}" 2>/dev/null || true
      codex_permission_deny "VIBEGUARD hook failed: wrapped hook exited nonzero."
      exit 0
    fi
    rm -f "${NORMALIZED_FILE}" 2>/dev/null || true
    exit 0
  fi

  if [[ -z "$HOOK_OUTPUT" ]]; then
    continue
  fi

  if [[ "$EVENT_NAME" == "PreToolUse" ]]; then
    pretool_status=0
    pretool_output=$(codex_adapt_pretool "$HOOK_OUTPUT") || pretool_status=$?
    if [[ ${pretool_status} -ne 0 ]]; then
      rm -f "${NORMALIZED_FILE}" 2>/dev/null || true
      if [[ -n "$pretool_output" ]]; then
        printf '%s\n' "$pretool_output"
      else
        codex_pretool_deny "VIBEGUARD hook failed: wrapped hook output could not be adapted."
      fi
      exit 0
    fi
    if [[ -n "$pretool_output" ]]; then
      if [[ "$pretool_output" == *'"permissionDecision": "deny"'* || "$pretool_output" == *'"permissionDecision":"deny"'* ]]; then
        rm -f "${NORMALIZED_FILE}" 2>/dev/null || true
        printf '%s\n' "$pretool_output"
        exit 0
      fi
      [[ -n "${FIRST_ADAPTED_OUTPUT}" ]] || FIRST_ADAPTED_OUTPUT="$pretool_output"
    fi
  elif [[ "$EVENT_NAME" == "PermissionRequest" ]]; then
    permission_status=0
    permission_output=$(codex_adapt_permission_request "$HOOK_OUTPUT") || permission_status=$?
    if [[ ${permission_status} -ne 0 ]]; then
      rm -f "${NORMALIZED_FILE}" 2>/dev/null || true
      if [[ -n "$permission_output" ]]; then
        printf '%s\n' "$permission_output"
      else
        codex_permission_deny "VIBEGUARD hook failed: wrapped hook output could not be adapted."
      fi
      exit 0
    fi
    if [[ -n "$permission_output" ]]; then
      if [[ "$permission_output" == *'"behavior": "deny"'* || "$permission_output" == *'"behavior":"deny"'* ]]; then
        rm -f "${NORMALIZED_FILE}" 2>/dev/null || true
        printf '%s\n' "$permission_output"
        exit 0
      fi
      [[ -n "${FIRST_ADAPTED_OUTPUT}" ]] || FIRST_ADAPTED_OUTPUT="$permission_output"
    fi
  elif [[ "$EVENT_NAME" == "PostToolUse" ]]; then
    posttool_status=0
    posttool_output=$(codex_adapt_posttool "$HOOK_OUTPUT" 2>/dev/null) || posttool_status=$?
    if [[ ${posttool_status} -ne 0 ]]; then
      codex_diag "${HOOK_NAME}" "${EVENT_NAME}" "posttool-adapter-failed" "$HOOK_OUTPUT"
      continue
    fi
    if [[ -n "${posttool_output}" ]]; then
      if [[ "$posttool_output" == *'"decision": "block"'* || "$posttool_output" == *'"decision":"block"'* ]]; then
        rm -f "${NORMALIZED_FILE}" 2>/dev/null || true
        printf '%s\n' "${posttool_output}"
        exit 0
      fi
      [[ -n "${FIRST_ADAPTED_OUTPUT}" ]] || FIRST_ADAPTED_OUTPUT="$posttool_output"
    fi
  else
    [[ -n "${FIRST_ADAPTED_OUTPUT}" ]] || FIRST_ADAPTED_OUTPUT="$HOOK_OUTPUT"
  fi
done <"${NORMALIZED_FILE}"

rm -f "${NORMALIZED_FILE}" 2>/dev/null || true
if [[ -n "${FIRST_ADAPTED_OUTPUT}" ]]; then
  printf '%s\n' "${FIRST_ADAPTED_OUTPUT}"
fi

exit 0

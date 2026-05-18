#!/usr/bin/env bash
# Shared runtime policy gate for VibeGuard hook wrappers.

if [[ -n "${_VG_POLICY_SH_LOADED:-}" ]]; then
  return 0
fi
_VG_POLICY_SH_LOADED=1

_VG_POLICY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_VG_POLICY_PY="${_VG_POLICY_LIB_DIR}/policy.py"

vg_policy_user_config_file() {
  printf '%s' "${_VG_CONFIG_FILE:-${VIBEGUARD_CONFIG_FILE:-${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}/config.json}}"
}

vg_policy_check_hook() {
  local hook_name="$1"
  local output status

  VG_POLICY_REASON=""
  VG_POLICY_KIND=""

  if ! command -v python3 >/dev/null 2>&1; then
    VG_POLICY_REASON="VibeGuard policy error: python3 is required for runtime policy checks."
    VG_POLICY_KIND="policy_error"
    return 20
  fi
  if [[ ! -f "${_VG_POLICY_PY}" ]]; then
    VG_POLICY_REASON="VibeGuard policy error: policy helper missing at ${_VG_POLICY_PY}"
    VG_POLICY_KIND="policy_error"
    return 20
  fi

  status=0
  output="$(
    VIBEGUARD_USER_CONFIG_FILE="$(vg_policy_user_config_file)" \
      python3 "${_VG_POLICY_PY}" check "${hook_name}" 2>&1
  )" || status=$?

  case "${status}" in
    0)
      return 0
      ;;
    10)
      VG_POLICY_REASON="${output}"
      VG_POLICY_KIND="policy_skip"
      return 10
      ;;
    30)
      VG_POLICY_REASON="${output}"
      VG_POLICY_KIND="config_parse_error"
      return 30
      ;;
    *)
      VG_POLICY_REASON="${output:-VibeGuard policy error: unknown runtime policy failure.}"
      VG_POLICY_KIND="policy_error"
      return 20
      ;;
  esac
}

vg_policy_diag() {
  local hook_name="$1" event_name="${2:-}" kind="$3" reason="$4"
  local diag_file diag_dir
  diag_file="${VIBEGUARD_POLICY_DIAG_FILE:-${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}/policy.jsonl}"
  diag_dir="$(dirname "${diag_file}")"
  mkdir -p "${diag_dir}" 2>/dev/null || return 0
  VIBEGUARD_POLICY_DIAG_HOOK="${hook_name}" \
    VIBEGUARD_POLICY_DIAG_EVENT="${event_name}" \
    VIBEGUARD_POLICY_DIAG_KIND="${kind}" \
    VIBEGUARD_POLICY_DIAG_REASON="${reason}" \
    VIBEGUARD_POLICY_DIAG_WRAPPER="${VIBEGUARD_WRAPPER:-unknown}" \
    python3 - <<'PY' >>"${diag_file}" 2>/dev/null || true
import json
import os
from datetime import datetime, timezone

print(json.dumps({
    "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "wrapper": os.environ.get("VIBEGUARD_POLICY_DIAG_WRAPPER", ""),
    "hook": os.environ.get("VIBEGUARD_POLICY_DIAG_HOOK", ""),
    "event": os.environ.get("VIBEGUARD_POLICY_DIAG_EVENT", ""),
    "kind": os.environ.get("VIBEGUARD_POLICY_DIAG_KIND", ""),
    "reason": os.environ.get("VIBEGUARD_POLICY_DIAG_REASON", ""),
}, ensure_ascii=False))
PY
}

vg_policy_codex_error_output() {
  local event_name="$1" reason="$2"
  VIBEGUARD_POLICY_EVENT="${event_name}" VIBEGUARD_POLICY_REASON="${reason}" python3 - <<'PY'
import json
import os

event = os.environ.get("VIBEGUARD_POLICY_EVENT", "")
reason = os.environ.get("VIBEGUARD_POLICY_REASON", "")
if event == "PreToolUse":
    payload = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }
elif event == "PermissionRequest":
    payload = {
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": {"behavior": "deny", "message": reason},
        }
    }
elif event == "PostToolUse":
    payload = {
        "decision": "block",
        "reason": reason,
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": reason,
        },
    }
else:
    payload = {"decision": "block", "reason": reason}
print(json.dumps(payload, ensure_ascii=False))
PY
}

vg_policy_codex_gate() {
  local hook_name="$1" event_name="$2" policy_status=0
  vg_policy_check_hook "${hook_name}" || policy_status=$?
  [[ ${policy_status} -eq 0 ]] && return 0

  vg_policy_diag "${hook_name}" "${event_name}" "${VG_POLICY_KIND}" "${VG_POLICY_REASON}"
  if declare -F codex_diag >/dev/null 2>&1; then
    codex_diag "${hook_name}" "${event_name}" "${VG_POLICY_KIND}" "${VG_POLICY_REASON}"
  fi
  [[ ${policy_status} -eq 10 ]] && return 1
  vg_policy_codex_error_output "${event_name}" "${VG_POLICY_REASON}"
  return 1
}

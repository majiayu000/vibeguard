#!/usr/bin/env bash
# VibeGuard PostToolUse(Read) Hook — Analysis Paralysis Guard
#
# Borrowed from GSD: detect consecutive Read calls without any Write/Edit action.
# After 5+ consecutive reads, warn the agent to either write code or report a blocker.
#
# Mechanism: count recent events in session log. If the last N tool uses are all
# Read/Glob/Grep (research tools) with no Write/Edit/Bash interleaved, trigger warning.
#
# Circuit breaker: after CB_THRESHOLD consecutive warns (default 3), the hook
# auto-passes for CB_COOLDOWN seconds (default 5 min) to prevent alert fatigue
# and the 716x warn loop documented in GitHub issue #10205.

set -euo pipefail

if [[ ! -t 0 ]]; then
  if ! INPUT="$(cat)"; then
    echo "ERROR: failed to drain analysis-paralysis hook stdin" >&2
    exit 1
  fi
else
  INPUT=""
fi

if [[ "${VIBEGUARD_SUPPRESS_PARALYSIS:-0}" == "1" ]]; then
  exit 0
fi

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/circuit-breaker.sh"
vg_start_timer
VG_EVENT_LOG_LIB="${VG_EVENT_LOG_LIB:-$(cd "$(dirname "$0")/_lib" && pwd)}"

analysis_tool_field() {
  local field="$1" value
  value="$(printf '%s' "${INPUT}" | vg_json_field "${field}" 2>/dev/null || true)"
  [[ -n "${value}" ]] && printf '%s' "${value}"
}

analysis_infer_tool() {
  local tool
  tool="$(analysis_tool_field "tool_name")"
  [[ -n "${tool}" ]] && { printf '%s\n' "${tool}"; return 0; }
  tool="$(analysis_tool_field "tool")"
  [[ -n "${tool}" ]] && { printf '%s\n' "${tool}"; return 0; }

  if [[ -n "$(analysis_tool_field "tool_input.command")" ]]; then
    printf '%s\n' "Bash"
  elif [[ -n "$(analysis_tool_field "tool_input.new_string")" || -n "$(analysis_tool_field "tool_input.old_string")" ]]; then
    printf '%s\n' "Edit"
  elif [[ -n "$(analysis_tool_field "tool_input.content")" ]]; then
    printf '%s\n' "Write"
  elif [[ -n "$(analysis_tool_field "tool_input.pattern")" ]]; then
    printf '%s\n' "Grep"
  elif [[ -n "$(analysis_tool_field "tool_input.file_path")" ]]; then
    printf '%s\n' "Read"
  elif [[ -z "${INPUT}" ]]; then
    printf '%s\n' "Read"
  else
    printf '%s\n' "PostToolUse"
  fi
}

analysis_is_research_tool() {
  case "$1" in
    Read|Glob|Grep) return 0 ;;
    *) return 1 ;;
  esac
}

_emit_cb_state_error() {
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "VIBEGUARD circuit breaker state error: analysis-paralysis-guard could not update its circuit breaker state; reporting visibly instead of silently auto-passing."
  }
}
EOF
}

# CI guard: analysis-paralysis warnings are not actionable in CI
vg_is_ci && exit 0

vg_config_get_int_result THRESHOLD VG_PARALYSIS_THRESHOLD paralysis.threshold 7
TOOL_NAME="$(analysis_infer_tool)"

if ! analysis_is_research_tool "${TOOL_NAME}"; then
  vg_log "analysis-paralysis-guard" "${TOOL_NAME}" "pass" "consecutive_reads=0 reset_by=${TOOL_NAME}" ""
  if ! vg_cb_record_pass "analysis-paralysis-guard"; then
    vg_log "analysis-paralysis-guard" "${TOOL_NAME}" "block" "Circuit breaker state error; fail-visible" ""
    _emit_cb_state_error
  fi
  exit 0
fi

# Count consecutive research-only tool calls (Read/Glob/Grep) at the tail of the session log.
# Exclude this hook's own log entries (hook == "analysis-paralysis-guard") to avoid self-inflation.
# Note: Glob/Grep hooks also log via this same hook (matcher: Read|Glob|Grep in settings.json).
# Read only last 300 lines to avoid O(n) full-file scan on long sessions
CONSECUTIVE=$(tail -300 "$VIBEGUARD_LOG_FILE" 2>/dev/null \
  | "$_VIBEGUARD_RUNTIME" paralysis-count "$VIBEGUARD_SESSION_ID" \
  2>/dev/null | tr -d '[:space:]' || echo "0")

CONSECUTIVE="${CONSECUTIVE:-0}"

# Log the triggering tool itself (always, regardless of circuit breaker state).
vg_log "analysis-paralysis-guard" "${TOOL_NAME}" "pass" "consecutive_reads=${CONSECUTIVE}" ""

if [[ "$CONSECUTIVE" -ge "$THRESHOLD" ]]; then
  # Circuit breaker check: if this hook has been firing repeatedly without
  # resolution, open the circuit and auto-pass to prevent 716x warn loops.
  CB_STATUS=0
  if vg_cb_check "analysis-paralysis-guard"; then
    CB_STATUS=0
  else
    CB_STATUS=$?
  fi

  if [[ "$CB_STATUS" -eq 0 ]]; then
    WARNING="[ANALYSIS PARALYSIS] There have been ${CONSECUTIVE} consecutive read-only operations (Read/Glob/Grep) without any writes. You may be stuck in a \"read-read\" loop. You must choose: (1) Start writing code/editing files (2) Report the blocker to the user and explain where it is stuck."

    vg_log "analysis-paralysis-guard" "${TOOL_NAME}" "warn" "W-13 paralysis ${CONSECUTIVE}x" ""
    if ! vg_cb_record_block "analysis-paralysis-guard"; then
      vg_log "analysis-paralysis-guard" "${TOOL_NAME}" "block" "Circuit breaker state error; fail-visible" ""
      _emit_cb_state_error
      exit 0
    fi

    printf '%s' "VIBEGUARD analysis paralysis warning:${WARNING}" \
      | "$_VIBEGUARD_RUNTIME" hook-context PostToolUse
  elif [[ "$CB_STATUS" -eq 1 ]]; then
    : # Circuit OPEN: vg_cb_check already logged the auto-pass.
  else
    vg_log "analysis-paralysis-guard" "${TOOL_NAME}" "block" "Circuit breaker state error; fail-visible" ""
    _emit_cb_state_error
  fi
else
  if ! vg_cb_record_pass "analysis-paralysis-guard"; then
    vg_log "analysis-paralysis-guard" "${TOOL_NAME}" "block" "Circuit breaker state error; fail-visible" ""
    _emit_cb_state_error
  fi
fi

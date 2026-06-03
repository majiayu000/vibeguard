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
  if ! cat >/dev/null; then
    echo "ERROR: failed to drain analysis-paralysis hook stdin" >&2
    exit 1
  fi
fi

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/circuit-breaker.sh"
vg_start_timer
VG_EVENT_LOG_LIB="${VG_EVENT_LOG_LIB:-$(cd "$(dirname "$0")/_lib" && pwd)}"

# CI guard: analysis-paralysis warnings are not actionable in CI
vg_is_ci && exit 0

THRESHOLD="$(vg_config_get_int VG_PARALYSIS_THRESHOLD paralysis.threshold 7)"

# Count consecutive research-only tool calls (Read/Glob/Grep) at the tail of the session log.
# Exclude this hook's own log entries (hook == "analysis-paralysis-guard") to avoid self-inflation.
# Note: Glob/Grep hooks also log via this same hook (matcher: Read|Glob|Grep in settings.json).
# Read only last 300 lines to avoid O(n) full-file scan on long sessions
CONSECUTIVE=$(tail -300 "$VIBEGUARD_LOG_FILE" 2>/dev/null \
  | "$_VIBEGUARD_RUNTIME" paralysis-count "$VIBEGUARD_SESSION_ID" \
  2>/dev/null | tr -d '[:space:]' || echo "0")

CONSECUTIVE="${CONSECUTIVE:-0}"

# Log the Read event itself (always, regardless of circuit breaker state)
vg_log "analysis-paralysis-guard" "Read" "pass" "consecutive_reads=${CONSECUTIVE}" ""

if [[ "$CONSECUTIVE" -ge "$THRESHOLD" ]]; then
  # Circuit breaker check: if this hook has been firing repeatedly without
  # resolution, open the circuit and auto-pass to prevent 716x warn loops.
  if vg_cb_check "analysis-paralysis-guard"; then
    WARNING="[ANALYSIS PARALYSIS] There have been ${CONSECUTIVE} consecutive read-only operations (Read/Glob/Grep) without any writes. You may be stuck in a \"read-read\" loop. You must choose: (1) Start writing code/editing files (2) Report the blocker to the user and explain where it is stuck."

    vg_log "analysis-paralysis-guard" "Read" "warn" "paralysis ${CONSECUTIVE}x" ""
    vg_cb_record_block "analysis-paralysis-guard"

    VG_WARNINGS="$WARNING" python3 -c '
import json, os
warnings = os.environ.get("VG_WARNINGS", "")
result = {
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": "VIBEGUARD analysis paralysis warning:" + warnings
    }
}
print(json.dumps(result, ensure_ascii=False))
'
  fi
  # If circuit is OPEN, vg_cb_check returned 1 and already logged the auto-pass.
  # We silently skip the warn to break the loop.
else
  vg_cb_record_pass "analysis-paralysis-guard"
fi

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

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/circuit-breaker.sh"

# CI guard: analysis-paralysis warnings are not actionable in CI
vg_is_ci && exit 0

THRESHOLD="${VG_PARALYSIS_THRESHOLD:-7}"

# Count consecutive research-only tool calls (Read/Glob/Grep) at the tail of the session log.
# Exclude this hook's own log entries (hook == "analysis-paralysis-guard") to avoid self-inflation.
# Note: Glob/Grep hooks also log via this same hook (matcher: Read|Glob|Grep in settings.json).
CONSECUTIVE=$(VG_LOG_FILE="$VIBEGUARD_LOG_FILE" VG_SESSION="$VIBEGUARD_SESSION_ID" VG_THRESHOLD="$THRESHOLD" python3 -c '
import json, os

log_file = os.environ.get("VG_LOG_FILE", "")
session = os.environ.get("VG_SESSION", "")
threshold = int(os.environ.get("VG_THRESHOLD", "7"))

research_tools = {"Read", "Glob", "Grep"}
action_tools = {"Write", "Edit", "Bash"}

consecutive = 0
try:
    with open(log_file) as f:
        events = []
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
                if e.get("session") == session:
                    events.append(e)
            except (json.JSONDecodeError, KeyError):
                continue

    # Walk backwards from the end.
    # Skip our own "warn" entries (they inflate the count), but count our "pass"
    # entries since those represent actual Read/Glob/Grep tool uses.
    for e in reversed(events):
        hook = e.get("hook", "")
        decision = e.get("decision", "")
        if hook == "analysis-paralysis-guard" and decision != "pass":
            continue  # skip warn/escalate entries to avoid count inflation
        tool = e.get("tool", "")
        if tool in research_tools:
            consecutive += 1
        elif tool in action_tools:
            break
        # Skip other hooks (post-guard-check, etc.)
except FileNotFoundError:
    pass

print(consecutive)
' 2>/dev/null | tr -d '[:space:]' || echo "0")

CONSECUTIVE="${CONSECUTIVE:-0}"

# Log the Read event itself (always, regardless of circuit breaker state)
vg_log "analysis-paralysis-guard" "Read" "pass" "consecutive_reads=${CONSECUTIVE}" ""

if [[ "$CONSECUTIVE" -ge "$THRESHOLD" ]]; then
  # Circuit breaker check: if this hook has been firing repeatedly without
  # resolution, open the circuit and auto-pass to prevent 716x warn loops.
  if vg_cb_check "analysis-paralysis-guard"; then
    WARNING="[ANALYSIS PARALYSIS] 已连续 ${CONSECUTIVE} 次只读操作（Read/Glob/Grep）没有任何写入。你可能陷入了"读了又读"循环。必须选择：(1) 动手写代码/编辑文件 (2) 向用户报告 blocker 并说明卡在哪里。"

    vg_log "analysis-paralysis-guard" "Read" "warn" "paralysis ${CONSECUTIVE}x" ""
    vg_cb_record_block "analysis-paralysis-guard"

    VG_WARNINGS="$WARNING" python3 -c '
import json, os
warnings = os.environ.get("VG_WARNINGS", "")
result = {
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": "VIBEGUARD 分析瘫痪警告：" + warnings
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

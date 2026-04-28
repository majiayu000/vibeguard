#!/usr/bin/env bash
# VibeGuard Session Metrics + Correction Detection — Stop event metric collection
#
# Benchmark the data collection layer of the Harness feedback loop:
# Collect session metrics → detect correction signals → write project-level metrics → for consumption by stats/gc/learn
#
# Correct signal detection (see Codex "mistake twice → retrospective"):
# - high warn rate (>40%) → low session quality
# - File churn (same file edited 5+ times) → repeated corrections
# - correction event exists → real-time correction detection triggered
# Output suggestions when significant signals are detected (not blocking)
set -euo pipefail
source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/circuit-breaker.sh"
vg_start_timer

# CI guard: skip in automated environments
vg_is_ci && exit 0

# Read stdin; check stop_hook_active to break Stop-hook chain loops
INPUT=$(cat 2>/dev/null || true)
vg_stop_hook_active "$INPUT" && exit 0

# Not in git repository → skip
if ! git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
  exit 0
fi

# Collect session metrics for the last 30 minutes of the current project + correct signal detection
if [[ -n "$_VG_HELPER" ]]; then
  # Pass the full log file — the 30-minute cutoff is enforced inside vg-helper,
  # so tail-limiting here would under-count events on busy sessions (>1000 events/30 min).
  LEARN_SUGGESTION=$("$_VG_HELPER" session-metrics "$VIBEGUARD_SESSION_ID" "$VIBEGUARD_PROJECT_LOG_DIR" \
    < "$VIBEGUARD_LOG_FILE" 2>/dev/null || true)
else
  _SESSION_METRICS_SCRIPT="$(dirname "$0")/_lib/session_metrics.py"
  LEARN_SUGGESTION=$(VIBEGUARD_LOG_FILE="$VIBEGUARD_LOG_FILE" \
    VIBEGUARD_SESSION_ID="$VIBEGUARD_SESSION_ID" \
    VIBEGUARD_PROJECT_LOG_DIR="$VIBEGUARD_PROJECT_LOG_DIR" \
    python3 "$_SESSION_METRICS_SCRIPT" 2>/dev/null || true)
fi

SIGNALS=""

# If a correction signal is detected, output suggestions (not blocking)
if [[ "$LEARN_SUGGESTION" == LEARN_SUGGESTED* ]]; then
  SIGNALS=$(echo "$LEARN_SUGGESTION" | tail -n +2)
  SIGNAL_COUNT=$(echo "$SIGNALS" | wc -l | tr -d ' ')

  verification_payload=$(
    VG_SIGNALS="$SIGNALS" \
    python3 - <<'PY'
import json
import os

signals = [line for line in os.environ.get("VG_SIGNALS", "").splitlines() if line.strip()]
print(
    json.dumps(
        {
            "source": "learn-evaluator",
            "status": "warn",
            "commands": [],
            "known_failures": signals,
            "summary": "Correction signals detected during stop-hook evaluation.",
            "turn_id": os.environ.get("VIBEGUARD_TURN_ID"),
            "session_id": os.environ.get("VIBEGUARD_SESSION_ID"),
        },
        ensure_ascii=False,
    )
)
PY
  )
  vg_omx_append_verification "$verification_payload" >/dev/null 2>&1 || true

  # Stop hook only supports top-level fields, hookSpecificOutput is not supported
  VG_SIGNALS="$SIGNALS" VG_COUNT="$SIGNAL_COUNT" python3 -c '
import json, os
signals = os.environ.get("VG_SIGNALS", "")
count = os.environ.get("VG_COUNT", "0")
signal_list = "; ".join(s for s in signals.strip().split("\n") if s)
msg = f"[VibeGuard correction detection] {count} signals: {signal_list}. It is recommended to run /vibeguard:learn"
result = {"stopReason": msg}
print(json.dumps(result, ensure_ascii=False))
'
fi

if [[ -n "${VIBEGUARD_VERIFICATION_STATUS:-}" ]]; then
  explicit_verification_payload=$(
    VG_STATUS="${VIBEGUARD_VERIFICATION_STATUS}" \
    VG_COMMANDS_JSON="${VIBEGUARD_VERIFICATION_COMMANDS_JSON:-[]}" \
    VG_KNOWN_FAILURES_JSON="${VIBEGUARD_KNOWN_FAILURES_JSON:-[]}" \
    VG_SUMMARY="${VIBEGUARD_VERIFICATION_SUMMARY:-}" \
    python3 - <<'PY'
import json
import os

commands = json.loads(os.environ.get("VG_COMMANDS_JSON", "[]"))
known_failures = json.loads(os.environ.get("VG_KNOWN_FAILURES_JSON", "[]"))
if not isinstance(commands, list):
    commands = []
if not isinstance(known_failures, list):
    known_failures = []
print(
    json.dumps(
        {
            "source": "learn-evaluator",
            "status": os.environ["VG_STATUS"],
            "commands": [item for item in commands if isinstance(item, str)],
            "known_failures": [item for item in known_failures if isinstance(item, str)],
            "summary": os.environ.get("VG_SUMMARY") or None,
            "turn_id": os.environ.get("VIBEGUARD_TURN_ID"),
            "session_id": os.environ.get("VIBEGUARD_SESSION_ID"),
        },
        ensure_ascii=False,
    )
)
PY
  )
  vg_omx_append_verification "$explicit_verification_payload" >/dev/null 2>&1 || true
fi

# Clean up the churn flag file of this session
find "${HOME}/.vibeguard/" -name ".churn_warned_${VIBEGUARD_SESSION_ID}_*" -delete 2>/dev/null || true

exit 0

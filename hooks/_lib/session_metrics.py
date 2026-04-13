#!/usr/bin/env python3
"""Session metrics collection and correction signal detection.

Reads events from VIBEGUARD_LOG_FILE (last 30 minutes), aggregates metrics,
detects correction signals, and writes to session-metrics.jsonl.

Environment variables (required):
  VIBEGUARD_LOG_FILE        — path to project events.jsonl
  VIBEGUARD_SESSION_ID      — current session ID
  VIBEGUARD_PROJECT_LOG_DIR — project log directory

Output: "LEARN_SUGGESTED\n<signal1>\n<signal2>..." if signals detected, else empty.
"""
import json
import sys
import os
from collections import Counter
from datetime import datetime, timezone, timedelta

log_file = os.environ["VIBEGUARD_LOG_FILE"]
if not os.path.exists(log_file):
    sys.exit(0)

cutoff = datetime.now(timezone.utc) - timedelta(minutes=30)
skip_hooks = {"stop-guard", "learn-evaluator"}
events = []
with open(log_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
            if event.get("hook", "") in skip_hooks:
                continue
            ts = event.get("ts", "")
            if ts:
                evt_time = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                if evt_time < cutoff:
                    continue
            events.append(event)
        except (json.JSONDecodeError, ValueError):
            continue

if len(events) < 3:
    sys.exit(0)

# Aggregation indicators
decisions = Counter(e.get("decision", "unknown") for e in events)
hooks = Counter(e.get("hook", "unknown") for e in events)
tools = Counter(e.get("tool", "unknown") for e in events)

edited_files = Counter(
    e.get("detail", "").split()[-1] if e.get("detail") else ""
    for e in events
    if e.get("tool") == "Edit" and e.get("detail")
)

durations = [e.get("duration_ms", 0) for e in events if e.get("duration_ms")]
avg_duration = sum(durations) // len(durations) if durations else 0

# --- Correction signal detection ---
correction_signals = []

# Signal 1: High warn rate (>40% of events are warn/block/escalate/correction)
total = len(events)
negative = (
    decisions.get("warn", 0)
    + decisions.get("block", 0)
    + decisions.get("escalate", 0)
    + decisions.get("correction", 0)
)
warn_ratio = negative / total if total > 0 else 0
if warn_ratio > 0.4 and negative >= 5:
    correction_signals.append(
        f"High friction session: {negative}/{total} event trigger warning ({warn_ratio:.0%})"
    )

# Signal 2: File churn (same file 5+ edits)
churn_files = [(f, c) for f, c in edited_files.most_common(3) if c >= 5 and f]
for f, c in churn_files:
    basename = os.path.basename(f)
    correction_signals.append(f"{basename} edited {c} times (repeated correction)")

# Signal 3: correction event already exists
correction_count = decisions.get("correction", 0)
if correction_count > 0:
    correction_signals.append(f"{correction_count} real-time correction detection triggers")

# Signal 4: escalate event
escalate_count = decisions.get("escalate", 0)
if escalate_count > 0:
    correction_signals.append(f"{escalate_count} upgrade warnings")

metrics = {
    "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "session": os.environ["VIBEGUARD_SESSION_ID"],
    "event_count": len(events),
    "decisions": dict(decisions),
    "hooks": dict(hooks),
    "tools": dict(tools),
    "top_edited_files": dict(edited_files.most_common(5)),
    "avg_duration_ms": avg_duration,
    "slow_ops": len([d for d in durations if d > 5000]),
    "correction_signals": correction_signals,
    "warn_ratio": round(warn_ratio, 2),
}

# Write project-level indicator files
metrics_file = os.path.join(os.environ["VIBEGUARD_PROJECT_LOG_DIR"], "session-metrics.jsonl")
with open(metrics_file, "a") as f:
    f.write(json.dumps(metrics, ensure_ascii=False) + "\n")

# Output suggestions when there is a correction signal
if correction_signals:
    print("LEARN_SUGGESTED")
    for sig in correction_signals:
        print(sig)

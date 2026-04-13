#!/usr/bin/env python3
"""Session metrics collection and correction signal detection.

Reads events from VIBEGUARD_LOG_FILE (last 30 minutes), aggregates metrics,
detects correction signals, and writes to session-metrics.jsonl.

Environment variables (required):
  VIBEGUARD_LOG_FILE        — path to project events.jsonl
  VIBEGUARD_SESSION_ID      — current session ID
  VIBEGUARD_PROJECT_LOG_DIR — project log directory

Output: "LEARN_SUGGESTED\n<signal1>\n<signal2>..." if signals detected, else empty.

Signal detection (10 types):
  1. High friction session (warn_ratio > 25%, negative >= 3)
  2. File churn (same file 3+ edits, excluding multi-file refactors)
  3. Real-time correction events
  4. Escalation events
  5. Block events (any block = learn signal)
  6. Analysis paralysis (7+ consecutive read-only ops)
  7. Rule repeat pattern (same rule triggered 3+ times in session)
  8. Build failure cluster (3+ build failures in session)
  9. Circuit breaker trips
  10. Warn trend regression (current session worse than project baseline)
"""
import json
import sys
import os
from collections import Counter, defaultdict
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

# Signal 1: High friction session (lowered threshold: 25% and >= 3)
total = len(events)
negative = (
    decisions.get("warn", 0)
    + decisions.get("block", 0)
    + decisions.get("escalate", 0)
    + decisions.get("correction", 0)
)
warn_ratio = negative / total if total > 0 else 0
if warn_ratio > 0.25 and negative >= 3:
    correction_signals.append(
        f"High friction session: {negative}/{total} events triggered warnings ({warn_ratio:.0%})"
    )

# Signal 2: File churn (lowered to 3+, but exclude multi-file refactors)
# If 5+ distinct files were edited, this is likely a refactor — raise churn threshold to 7
distinct_edited = sum(1 for f, c in edited_files.items() if f and c >= 1)
churn_threshold = 7 if distinct_edited >= 5 else 3
churn_files = [(f, c) for f, c in edited_files.most_common(5) if c >= churn_threshold and f]
for f, c in churn_files:
    basename = os.path.basename(f)
    correction_signals.append(f"{basename} edited {c} times (repeated correction)")

# Signal 3: Real-time correction events
correction_count = decisions.get("correction", 0)
if correction_count > 0:
    correction_signals.append(f"{correction_count} real-time correction detection triggers")

# Signal 4: Escalation events
escalate_count = decisions.get("escalate", 0)
if escalate_count > 0:
    correction_signals.append(f"{escalate_count} upgrade warnings")

# Signal 5: Block events (any block is significant)
block_count = decisions.get("block", 0)
if block_count > 0:
    block_reasons = [
        e.get("reason", "unknown")[:60]
        for e in events
        if e.get("decision") == "block"
    ]
    unique_reasons = list(dict.fromkeys(block_reasons))[:3]
    correction_signals.append(
        f"{block_count} block(s): {'; '.join(unique_reasons)}"
    )

# Signal 6: Analysis paralysis detected
paralysis_events = [e for e in events if "paralysis" in e.get("reason", "")]
if len(paralysis_events) >= 2:
    max_depth = 0
    for e in paralysis_events:
        reason = e.get("reason", "")
        # Extract depth number like "paralysis 9x"
        for part in reason.split():
            if part.endswith("x") and part[:-1].isdigit():
                max_depth = max(max_depth, int(part[:-1]))
    correction_signals.append(
        f"Analysis paralysis: {len(paralysis_events)} triggers (max depth {max_depth}x)"
    )

# Signal 7: Same rule triggered 3+ times in session
rule_counter = Counter()
for e in events:
    if e.get("decision") in ("warn", "block", "escalate"):
        reason = e.get("reason", "")
        if "[" in reason and "]" in reason:
            tag = reason.split("]")[0] + "]"
            rule_counter[tag] += 1

repeat_rules = [(tag, count) for tag, count in rule_counter.most_common() if count >= 3]
for tag, count in repeat_rules[:3]:
    correction_signals.append(f"Rule {tag} triggered {count} times (pattern)")

# Signal 8: Build failure cluster (3+ build failures)
build_failures = sum(
    1 for e in events
    if "构建错误" in e.get("reason", "") or "build fail" in e.get("reason", "").lower()
)
if build_failures >= 3:
    correction_signals.append(f"{build_failures} build failures in session (spiral risk)")

# Signal 9: Circuit breaker trips
cb_trips = sum(
    1 for e in events
    if "CB tripped" in e.get("reason", "")
)
if cb_trips > 0:
    correction_signals.append(f"Circuit breaker tripped {cb_trips} time(s)")

# Signal 10: Warn trend regression (compare with project baseline)
metrics_file = os.path.join(os.environ["VIBEGUARD_PROJECT_LOG_DIR"], "session-metrics.jsonl")
if os.path.exists(metrics_file):
    try:
        recent_ratios = []
        with open(metrics_file) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                m = json.loads(line)
                r = m.get("warn_ratio", 0)
                if r > 0:
                    recent_ratios.append(r)
        if len(recent_ratios) >= 10:
            baseline = sum(recent_ratios[-20:]) / len(recent_ratios[-20:])
            if warn_ratio > baseline * 2 and warn_ratio > 0.1:
                correction_signals.append(
                    f"Warn rate regression: {warn_ratio:.0%} vs baseline {baseline:.0%} (2x+)"
                )
    except (json.JSONDecodeError, ValueError, OSError):
        pass

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
with open(metrics_file, "a") as f:
    f.write(json.dumps(metrics, ensure_ascii=False) + "\n")

# Output suggestions when there is a correction signal
if correction_signals:
    print("LEARN_SUGGESTED")
    for sig in correction_signals:
        print(sig)

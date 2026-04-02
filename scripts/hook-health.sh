#!/usr/bin/env bash
# VibeGuard Hook Health Snapshot
# Read events.jsonl and output the health snapshot of the last N hours.
#
# Usage:
# bash scripts/hook-health.sh # Last 24 hours
# bash scripts/hook-health.sh 72 # Last 72 hours

set -euo pipefail

HOURS="${1:-24}"
LOG_FILE="${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}/events.jsonl"

if ! [[ "${HOURS}" =~ ^[0-9]+$ ]] || [[ "${HOURS}" -le 0 ]]; then
  echo "The argument must be a positive integer number of hours, for example: 24"
  exit 1
fi

if [[ ! -f "${LOG_FILE}" ]]; then
  echo "No log data. Hooks will be automatically logged to ${LOG_FILE} after being triggered."
  exit 0
fi

VG_HOURS="${HOURS}" VG_LOG_FILE="${LOG_FILE}" python3 - <<'PY'
import json
import os
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone


def parse_ts(ts: str):
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None


hours = int(os.environ["VG_HOURS"])
log_file = os.environ["VG_LOG_FILE"]
now = datetime.now(timezone.utc)
cutoff = now - timedelta(hours=hours)

events = []
with open(log_file, "r", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        event_ts = parse_ts(event.get("ts", ""))
        if event_ts is None:
            continue
        if event_ts >= cutoff:
            event["_parsed_ts"] = event_ts
            events.append(event)

if not events:
    print(f"No log data for the last {hours} hours.")
    sys.exit(0)

events.sort(key=lambda e: e["_parsed_ts"])
total = len(events)
by_decision = Counter(e.get("decision", "unknown") for e in events)
pass_count = by_decision.get("pass", 0)
risk_count = total - pass_count
risk_rate = (risk_count / total * 100) if total else 0.0

first_ts = events[0].get("ts", "?")
last_ts = events[-1].get("ts", "?")

print(f"VibeGuard Hook Health (last {hours} hours)")
print("=" * 44)
print(f"Time range: {first_ts} ~ {last_ts}")
print(f"Total triggers: {total}")
print(f"Pass: {pass_count}")
print(f"Risk (non-pass): {risk_count}")
print(f"Risk rate: {risk_rate:.1f}%")
print(f"  block: {by_decision.get('block', 0)}")
print(f"  gate: {by_decision.get('gate', 0)}")
print(f"  warn: {by_decision.get('warn', 0)}")
print(f"  escalate: {by_decision.get('escalate', 0)}")
print(f"  correction: {by_decision.get('correction', 0)}")

non_pass_events = [e for e in events if e.get("decision") != "pass"]
if non_pass_events:
    top_non_pass_hooks = Counter(e.get("hook", "unknown") for e in non_pass_events)
    print("\nRisk Hook Top 5:")
    for hook, count in top_non_pass_hooks.most_common(5):
        print(f"  {hook}: {count}")

    print("\nTop 10 recent risk events:")
    for i, event in enumerate(reversed(non_pass_events[-10:]), start=1):
        ts = event.get("ts", "?")
        session = event.get("session", "?")
        hook = event.get("hook", "unknown")
        decision = event.get("decision", "unknown")
        reason = (event.get("reason") or "").replace("\n", " ").strip()
        detail = (event.get("detail") or "").replace("\n", " ").strip()
        if len(reason) > 100:
            reason = reason[:97] + "..."
        if len(detail) > 100:
            detail = detail[:97] + "..."
        print(f"  {i}. {ts} | {hook} | {decision} | session={session}")
        if reason:
            print(f"     reason: {reason}")
        if detail:
            print(f"     detail: {detail}")

print()
PY

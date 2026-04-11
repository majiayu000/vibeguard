#!/usr/bin/env bash
# VibeGuard — Prometheus metrics export
#
# Read events.jsonl and output Prometheus text format indicators.
# Support pushing to Pushgateway or writing to textfile collector.
#
# Usage:
# bash metrics-exporter.sh # Output to stdout
# bash metrics-exporter.sh --push <gateway> # Push to Pushgateway
# bash metrics-exporter.sh --file <path> # Write textfile

set -euo pipefail

LOG_DIR="${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}"
LOG_FILE="${LOG_DIR}/events.jsonl"
PUSH_URL=""
OUTPUT_FILE=""
DAYS=7

while [[ $# -gt 0 ]]; do
  case "$1" in
    --push) PUSH_URL="$2"; shift 2 ;;
    --file) OUTPUT_FILE="$2"; shift 2 ;;
    --days) DAYS="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ ! -f "$LOG_FILE" ]]; then
  echo "# Log file does not exist: ${LOG_FILE}" >&2
  exit 0
fi

# Generate Prometheus metrics
METRICS=$(python3 -c "
import json, sys
from collections import defaultdict
from datetime import datetime, timezone, timedelta

log_file = '${LOG_FILE}'
days = ${DAYS}
cutoff = datetime.now(timezone.utc) - timedelta(days=days)

# counter
hook_total = defaultdict(int)       # {(hook, decision): count}
tool_total = defaultdict(int)       # {tool: count}
duration_sum = defaultdict(float)   # {hook: sum_ms}
duration_count = defaultdict(int)   # {hook: count}
violation_total = defaultdict(int)  # {reason: count}

total_events = 0

with open(log_file, encoding='utf-8', errors='replace') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue

        ts = event.get('ts', '')
        try:
            event_time = datetime.fromisoformat(ts.replace('Z', '+00:00'))
            if event_time < cutoff:
                continue
        except (ValueError, AttributeError):
            continue

        total_events += 1
        hook = event.get('hook', 'unknown')
        tool = event.get('tool', 'unknown')
        decision = event.get('decision', 'unknown')
        reason = event.get('reason', '')
        duration = event.get('duration_ms')

        hook_total[(hook, decision)] += 1
        tool_total[tool] += 1

        if duration is not None:
            duration_sum[hook] += float(duration) / 1000.0
            duration_count[hook] += 1

        if decision in ('warn', 'block', 'gate'):
            violation_total[reason or 'unspecified'] += 1

# Output Prometheus format
print('# HELP vibeguard_hook_trigger_total Total hook triggers by hook and decision')
print('# TYPE vibeguard_hook_trigger_total counter')
for (hook, decision), count in sorted(hook_total.items()):
    print(f'vibeguard_hook_trigger_total{{hook=\"{hook}\",decision=\"{decision}\"}} {count}')

print()
print('# HELP vibeguard_tool_total Total events by tool type')
print('# TYPE vibeguard_tool_total counter')
for tool, count in sorted(tool_total.items()):
    print(f'vibeguard_tool_total{{tool=\"{tool}\"}} {count}')

print()
print('# HELP vibeguard_hook_duration_seconds Total hook execution duration in seconds')
print('# TYPE vibeguard_hook_duration_seconds summary')
for hook in sorted(duration_sum.keys()):
    print(f'vibeguard_hook_duration_seconds_sum{{hook=\"{hook}\"}} {duration_sum[hook]:.3f}')
    print(f'vibeguard_hook_duration_seconds_count{{hook=\"{hook}\"}} {duration_count[hook]}')

print()
print('# HELP vibeguard_guard_violation_total Total guard violations by reason')
print('# TYPE vibeguard_guard_violation_total counter')
for reason, count in sorted(violation_total.items()):
    safe_reason = reason.replace('\"', '').replace('\\\\', '').replace('\n', ' ').replace('\r', '')[:80]
    print(f'vibeguard_guard_violation_total{{reason=\"{safe_reason}\"}} {count}')

print()
print('# HELP vibeguard_events_total Total events in period')
print('# TYPE vibeguard_events_total gauge')
print(f'vibeguard_events_total {total_events}')
")

if [[ -n "$OUTPUT_FILE" ]]; then
  echo "$METRICS" > "$OUTPUT_FILE"
  echo "Indicator written: ${OUTPUT_FILE}"
elif [[ -n "$PUSH_URL" ]]; then
  echo "$METRICS" | curl --silent --data-binary @- "${PUSH_URL}/metrics/job/vibeguard"
  echo "The indicator has been pushed to: ${PUSH_URL}"
else
  echo "$METRICS"
fi

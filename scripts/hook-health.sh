#!/usr/bin/env bash
# VibeGuard Hook Health Snapshot
# 读取 events.jsonl，输出最近 N 小时的健康快照。
#
# 用法：
#   bash scripts/hook-health.sh        # 最近 24 小时
#   bash scripts/hook-health.sh 72     # 最近 72 小时

set -euo pipefail

HOURS="${1:-24}"
LOG_FILE="${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}/events.jsonl"

if ! [[ "${HOURS}" =~ ^[0-9]+$ ]] || [[ "${HOURS}" -le 0 ]]; then
  echo "参数必须是正整数小时数，例如: 24"
  exit 1
fi

if [[ ! -f "${LOG_FILE}" ]]; then
  echo "没有日志数据。hooks 触发后会自动记录到 ${LOG_FILE}"
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
    print(f"最近 {hours} 小时没有日志数据。")
    sys.exit(0)

events.sort(key=lambda e: e["_parsed_ts"])
total = len(events)
by_decision = Counter(e.get("decision", "unknown") for e in events)
pass_count = by_decision.get("pass", 0)
risk_count = total - pass_count
risk_rate = (risk_count / total * 100) if total else 0.0

first_ts = events[0].get("ts", "?")
last_ts = events[-1].get("ts", "?")

print(f"VibeGuard Hook Health (最近 {hours} 小时)")
print("=" * 44)
print(f"时间范围: {first_ts} ~ {last_ts}")
print(f"总触发: {total}")
print(f"通过(pass): {pass_count}")
print(f"风险(非 pass): {risk_count}")
print(f"风险率: {risk_rate:.1f}%")
print(f"  block: {by_decision.get('block', 0)}")
print(f"  gate: {by_decision.get('gate', 0)}")
print(f"  warn: {by_decision.get('warn', 0)}")
print(f"  escalate: {by_decision.get('escalate', 0)}")
print(f"  correction: {by_decision.get('correction', 0)}")

non_pass_events = [e for e in events if e.get("decision") != "pass"]
if non_pass_events:
    top_non_pass_hooks = Counter(e.get("hook", "unknown") for e in non_pass_events)
    print("\n风险 Hook Top 5:")
    for hook, count in top_non_pass_hooks.most_common(5):
        print(f"  {hook}: {count}")

    print("\n最近风险事件 Top 10:")
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

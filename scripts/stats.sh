#!/usr/bin/env bash
# VibeGuard 统计脚本
# 分析 ~/.vibeguard/events.jsonl，输出 hook 触发统计
#
# 用法：
#   bash stats.sh           # 最近 7 天
#   bash stats.sh 30        # 最近 30 天
#   bash stats.sh all       # 全部历史

set -euo pipefail

DAYS="${1:-7}"
LOG_FILE="${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}/events.jsonl"

if [[ ! -f "$LOG_FILE" ]]; then
  echo "没有日志数据。hooks 触发后会自动记录到 $LOG_FILE"
  exit 0
fi

VG_DAYS="$DAYS" VG_LOG_FILE="$LOG_FILE" python3 -c "
import json, sys, os
from datetime import datetime, timezone, timedelta
from collections import Counter

days = os.environ.get('VG_DAYS', '7')
log_file = os.environ.get('VG_LOG_FILE', '')

# 读取事件
events = []
with open(log_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue

if not events:
    print('没有日志数据。')
    sys.exit(0)

# 时间过滤
if days != 'all':
    cutoff = datetime.now(timezone.utc) - timedelta(days=int(days))
    cutoff_str = cutoff.strftime('%Y-%m-%dT%H:%M:%SZ')
    events = [e for e in events if e.get('ts', '') >= cutoff_str]

if not events:
    print(f'最近 {days} 天没有日志数据。')
    sys.exit(0)

period = f'全部历史' if days == 'all' else f'最近 {days} 天'

# 统计
total = len(events)
by_decision = Counter(e.get('decision', 'unknown') for e in events)
by_hook = Counter(e.get('hook', 'unknown') for e in events)

blocks = [e for e in events if e.get('decision') == 'block']
warns = [e for e in events if e.get('decision') == 'warn']
passes = [e for e in events if e.get('decision') == 'pass']

block_reasons = Counter(e.get('reason', '未知') for e in blocks)
warn_reasons = Counter(e.get('reason', '未知') for e in warns)

# 时间范围
first_ts = events[0].get('ts', '?')
last_ts = events[-1].get('ts', '?')

# 输出
print(f'''
VibeGuard 统计 ({period})
{'=' * 40}
时间范围: {first_ts} ~ {last_ts}
总触发: {total} 次
  拦截 (block): {by_decision.get('block', 0)} 次
  警告 (warn):  {by_decision.get('warn', 0)} 次
  放行 (pass):  {by_decision.get('pass', 0)} 次
''')

print(f'按 Hook 分布:')
for hook, count in by_hook.most_common():
    print(f'  {hook}: {count} 次')

if block_reasons:
    print(f'\n拦截原因 Top 5:')
    for reason, count in block_reasons.most_common(5):
        short = reason[:60] + '...' if len(reason) > 60 else reason
        print(f'  {count}x  {short}')

if warn_reasons:
    print(f'\n警告原因 Top 5:')
    for reason, count in warn_reasons.most_common(5):
        short = reason[:60] + '...' if len(reason) > 60 else reason
        print(f'  {count}x  {short}')

# 日活跃度（按天分组）
by_day = Counter()
for e in events:
    day = e.get('ts', '')[:10]
    if day:
        by_day[day] += 1

if len(by_day) > 1:
    print(f'\n每日触发量:')
    for day in sorted(by_day.keys())[-7:]:
        bar = '█' * min(by_day[day], 50)
        print(f'  {day}  {bar} {by_day[day]}')

print()
"

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

# --- Warn 遵守率分析 ---
# 检查 warn 事件后，同一 hook + 同一文件是否有对应的 pass 事件
if warns:
    print(f'\n== Warn 遵守率分析 ==')
    warn_keys = {}  # (hook, file_ext) -> [warn_events]
    for w in warns:
        hook = w.get('hook', '')
        detail = w.get('detail', '')
        ext = ''
        # 从 detail 中提取文件扩展名
        for part in detail.split():
            if '.' in part:
                ext = part.rsplit('.', 1)[-1][:5]
                break
        key = (hook, ext)
        warn_keys.setdefault(key, []).append(w)

    # 对每个 warn 模式，检查后续是否有同 hook 的 pass
    # 简化逻辑：按 hook 统计 warn/pass 比
    by_hook_decision = {}
    for e in events:
        hook = e.get('hook', '')
        dec = e.get('decision', '')
        if dec in ('warn', 'pass'):
            by_hook_decision.setdefault(hook, Counter())[dec] += 1

    upgrade_candidates = []
    for hook, counts in sorted(by_hook_decision.items()):
        w_count = counts.get('warn', 0)
        p_count = counts.get('pass', 0)
        total_wp = w_count + p_count
        if total_wp == 0:
            continue
        compliance = p_count / total_wp * 100
        if w_count > 0:
            indicator = 'OK' if compliance >= 80 else 'LOW'
            print(f'  {hook}: warn={w_count} pass={p_count} 遵守率={compliance:.0f}% [{indicator}]')
            if compliance < 50 and w_count >= 3:
                upgrade_candidates.append((hook, w_count, compliance))

    if upgrade_candidates:
        print(f'\n建议升级为 block（遵守率 < 50% 且 warn >= 3 次）:')
        for hook, count, rate in upgrade_candidates:
            print(f'  {hook}: {count} 次 warn, 遵守率 {rate:.0f}%')

# --- 按文件扩展名分布 ---
ext_counter = Counter()
for e in events:
    detail = e.get('detail', '')
    for part in detail.split():
        if '.' in part:
            ext = part.rsplit('.', 1)[-1][:5]
            if ext and ext.isalpha():
                ext_counter[ext] += 1
                break

if ext_counter:
    print(f'\n按文件类型分布:')
    for ext, count in ext_counter.most_common(10):
        print(f'  .{ext}: {count} 次')

# --- 按时段分布 ---
work_hours = 0
off_hours = 0
for e in events:
    ts = e.get('ts', '')
    if len(ts) >= 13:
        try:
            hour = int(ts[11:13])
            if 9 <= hour < 18:
                work_hours += 1
            else:
                off_hours += 1
        except ValueError:
            pass

if work_hours + off_hours > 0:
    print(f'\n按时段分布:')
    print(f'  工作时间 (09-18): {work_hours} 次 ({work_hours*100//(work_hours+off_hours)}%)')
    print(f'  非工作时间: {off_hours} 次 ({off_hours*100//(work_hours+off_hours)}%)')

# --- 效能分析（按 session 维度） ---
sessions = {}
for e in events:
    sid = e.get('session', '')
    if not sid:
        continue
    sessions.setdefault(sid, []).append(e)

if sessions:
    print(f'\n== 效能分析 ==')
    print(f'会话总数: {len(sessions)}')

    # 每会话平均触发次数
    trigger_counts = [len(evts) for evts in sessions.values()]
    avg_triggers = sum(trigger_counts) / len(trigger_counts)
    print(f'每会话平均触发: {avg_triggers:.1f} 次')

    # 每会话 block/warn 率
    session_block_rates = []
    session_warn_rates = []
    for sid, evts in sessions.items():
        total_s = len(evts)
        blocks_s = sum(1 for e in evts if e.get('decision') == 'block')
        warns_s = sum(1 for e in evts if e.get('decision') == 'warn')
        session_block_rates.append(blocks_s / total_s * 100 if total_s else 0)
        session_warn_rates.append(warns_s / total_s * 100 if total_s else 0)

    avg_block_rate = sum(session_block_rates) / len(session_block_rates)
    avg_warn_rate = sum(session_warn_rates) / len(session_warn_rates)
    print(f'每会话平均拦截率: {avg_block_rate:.1f}%')
    print(f'每会话平均警告率: {avg_warn_rate:.1f}%')

    # 确定性节点节省 token 估算
    # 假设：每次确定性检查（pass/block）替代一次 LLM 判断约 500 token
    TOKEN_PER_CHECK = 500
    deterministic_checks = sum(1 for e in events if e.get('decision') in ('pass', 'block', 'warn'))
    saved_tokens = deterministic_checks * TOKEN_PER_CHECK
    if saved_tokens >= 1_000_000:
        print(f'确定性节点估算节省: ~{saved_tokens/1_000_000:.1f}M tokens')
    elif saved_tokens >= 1_000:
        print(f'确定性节点估算节省: ~{saved_tokens/1_000:.0f}K tokens')
    else:
        print(f'确定性节点估算节省: ~{saved_tokens} tokens')

    # 问题会话 Top 3（block+warn 最多的会话）
    problem_sessions = sorted(
        sessions.items(),
        key=lambda x: sum(1 for e in x[1] if e.get('decision') in ('block', 'warn')),
        reverse=True
    )[:3]
    has_problems = any(
        sum(1 for e in evts if e.get('decision') in ('block', 'warn')) > 0
        for _, evts in problem_sessions
    )
    if has_problems:
        print(f'\n问题最多的会话 Top 3:')
        for sid, evts in problem_sessions:
            issues = sum(1 for e in evts if e.get('decision') in ('block', 'warn'))
            if issues == 0:
                break
            ts_start = evts[0].get('ts', '?')[:16]
            ts_end = evts[-1].get('ts', '?')[:16]
            print(f'  {sid}: {issues} 个问题 / {len(evts)} 次触发 ({ts_start} ~ {ts_end})')

print()
"

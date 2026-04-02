#!/usr/bin/env bash
# VibeGuard statistics script
# Analyze ~/.vibeguard/events.jsonl and output hook trigger statistics
#
# Usage:
# bash stats.sh # Last 7 days
# bash stats.sh 30 # Last 30 days
# bash stats.sh all # All history

set -euo pipefail

DAYS="${1:-7}"
LOG_FILE="${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}/events.jsonl"

if [[ ! -f "$LOG_FILE" ]]; then
  echo "No log data. Hooks will be automatically logged to $LOG_FILE after being triggered"
  exit 0
fi

VG_DAYS="$DAYS" VG_LOG_FILE="$LOG_FILE" python3 -c "
import json, sys, os
from datetime import datetime, timezone, timedelta
from collections import Counter

days = os.environ.get('VG_DAYS', '7')
log_file = os.environ.get('VG_LOG_FILE', '')

#Read events
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
    print('No log data.')
    sys.exit(0)

# Time filter
if days != 'all':
    cutoff = datetime.now(timezone.utc) - timedelta(days=int(days))
    cutoff_str = cutoff.strftime('%Y-%m-%dT%H:%M:%SZ')
    events = [e for e in events if e.get('ts', '') >= cutoff_str]

if not events:
    print(f'No log data for the last {days} days.')
    sys.exit(0)

period = f'all history' if days == 'all' else f'last {days} days'

# Statistics
total = len(events)
by_decision = Counter(e.get('decision', 'unknown') for e in events)
by_hook = Counter(e.get('hook', 'unknown') for e in events)

blocks = [e for e in events if e.get('decision') == 'block']
warns = [e for e in events if e.get('decision') == 'warn']
passes = [e for e in events if e.get('decision') == 'pass']

block_reasons = Counter(e.get('reason', 'Unknown') for e in blocks)
warn_reasons = Counter(e.get('reason', 'Unknown') for e in warns)

# time range
first_ts = events[0].get('ts', '?')
last_ts = events[-1].get('ts', '?')

# output
print(f'''
VibeGuard Statistics ({period})
{'=' * 40}
Time range: {first_ts} ~ {last_ts}
Total triggers: {total} times
  Interception (block): {by_decision.get('block', 0)} times
  Warning: {by_decision.get('warn', 0)} times
  Pass (pass): {by_decision.get('pass', 0)} times
''')

print(f'Distributed by Hook:')
for hook, count in by_hook.most_common():
    print(f' {hook}: {count} times')

if block_reasons:
    print(f'\nInterception reasons Top 5:')
    for reason, count in block_reasons.most_common(5):
        short = reason[:60] + '...' if len(reason) > 60 else reason
        print(f'  {count}x  {short}')

if warn_reasons:
    print(f'\nWarning reasons Top 5:')
    for reason, count in warn_reasons.most_common(5):
        short = reason[:60] + '...' if len(reason) > 60 else reason
        print(f'  {count}x  {short}')

# Daily activity (grouped by day)
by_day = Counter()
for e in events:
    day = e.get('ts', '')[:10]
    if day:
        by_day[day] += 1

if len(by_day) > 1:
    print(f'\nDaily trigger amount:')
    for day in sorted(by_day.keys())[-7:]:
        bar = '█' * min(by_day[day], 50)
        print(f'  {day}  {bar} {by_day[day]}')

# --- Warn Compliance Rate Analysis ---
# Check whether the same hook + the same file has a corresponding pass event after the warn event
if warns:
    print(f'\n== Warn compliance rate analysis ==')
    warn_keys = {}  # (hook, file_ext) -> [warn_events]
    for w in warns:
        hook = w.get('hook', '')
        detail = w.get('detail', '')
        ext = ''
        # Extract file extension from detail
        for part in detail.split():
            if '.' in part:
                ext = part.rsplit('.', 1)[-1][:5]
                break
        key = (hook, ext)
        warn_keys.setdefault(key, []).append(w)

    # For each warn mode, check whether there is a subsequent pass with the same hook
    # Simplify logic: count warn/pass ratio by hook
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
            print(f' {hook}: warn={w_count} pass={p_count} compliance rate={compliance:.0f}% [{indicator}]')
            if compliance < 50 and w_count >= 3:
                upgrade_candidates.append((hook, w_count, compliance))

    if upgrade_candidates:
        print(f'\nIt is recommended to upgrade to block (compliance rate < 50% and warn >= 3 times):')
        for hook, count, rate in upgrade_candidates:
            print(f' {hook}: {count} times warn, compliance rate {rate:.0f}%')

# --- Distribute by file extension ---
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
    print(f'\nDistributed by file type:')
    for ext, count in ext_counter.most_common(10):
        print(f' .{ext}: {count} times')

# --- Distribution by time period ---
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
    print(f'\nDistributed by time period:')
    print(f' working time (09-18): {work_hours} times ({work_hours*100//(work_hours+off_hours)}%)')
    print(f' Non-working hours: {off_hours} times ({off_hours*100//(work_hours+off_hours)}%)')

# --- Performance analysis (by session dimension) ---
sessions = {}
for e in events:
    sid = e.get('session', '')
    if not sid:
        continue
    sessions.setdefault(sid, []).append(e)

if sessions:
    print(f'\n== Performance analysis ==')
    print(f'Total number of sessions: {len(sessions)}')

    # Average number of triggers per session
    trigger_counts = [len(evts) for evts in sessions.values()]
    avg_triggers = sum(trigger_counts) / len(trigger_counts)
    print(f'Average triggers per session: {avg_triggers:.1f} times')

    # Per session block/warn rate
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
    print(f'Average block rate per session: {avg_block_rate:.1f}%')
    print(f'Average warning rate per session: {avg_warn_rate:.1f}%')

    # Deterministic node saving token estimation
    # Assumption: Each deterministic check (pass/block) replaces an LLM judgment and costs about 500 tokens
    TOKEN_PER_CHECK = 500
    deterministic_checks = sum(1 for e in events if e.get('decision') in ('pass', 'block', 'warn'))
    saved_tokens = deterministic_checks * TOKEN_PER_CHECK
    if saved_tokens >= 1_000_000:
        print(f'Deterministic node estimated savings: ~{saved_tokens/1_000_000:.1f}M tokens')
    elif saved_tokens >= 1_000:
        print(f'Deterministic node estimated savings: ~{saved_tokens/1_000:.0f}K tokens')
    else:
        print(f'Deterministic node estimated savings: ~{saved_tokens} tokens')

    #Top 3 problem sessions (those with the most block+warn)
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
        print(f'\nConversations with the most questions Top 3:')
        for sid, evts in problem_sessions:
            issues = sum(1 for e in evts if e.get('decision') in ('block', 'warn'))
            if issues == 0:
                break
            ts_start = evts[0].get('ts', '?')[:16]
            ts_end = evts[-1].get('ts', '?')[:16]
            print(f' {sid}: {issues} issues / {len(evts)} triggers ({ts_start} ~ {ts_end})')

print()
"

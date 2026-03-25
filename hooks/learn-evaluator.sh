#!/usr/bin/env bash
# VibeGuard Session Metrics + Correction Detection — Stop 事件指标采集
#
# 对标 Harness 反馈循环的数据采集层：
# 收集会话指标 → 检测纠正信号 → 写入项目级 metrics → 供 stats/gc/learn 消费
#
# 纠正信号检测（借鉴 Codex "mistake twice → retrospective"）：
# - 高 warn 比率（>40%）→ 会话质量低
# - 文件 churn（同文件 5+ 次编辑）→ 反复修正
# - correction 事件存在 → 已触发实时纠正检测
# 检测到显著信号时输出建议（不阻塞）
set -euo pipefail
source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/circuit-breaker.sh"

# CI guard: skip in automated environments
vg_is_ci && exit 0

# Read stdin; check stop_hook_active to break Stop-hook chain loops
INPUT=$(cat 2>/dev/null || true)
vg_stop_hook_active "$INPUT" && exit 0

# 不在 git 仓库 → 跳过
if ! git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
  exit 0
fi

# 采集当前项目最近 30 分钟的会话指标 + 纠正信号检测
LEARN_SUGGESTION=$(python3 -c "
import json, sys, os
from collections import Counter
from datetime import datetime, timezone, timedelta

log_file = '${VIBEGUARD_LOG_FILE}'
if not os.path.exists(log_file):
    sys.exit(0)

cutoff = datetime.now(timezone.utc) - timedelta(minutes=30)
skip_hooks = {'stop-guard', 'learn-evaluator'}
events = []
with open(log_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
            if event.get('hook', '') in skip_hooks:
                continue
            ts = event.get('ts', '')
            if ts:
                evt_time = datetime.fromisoformat(ts.replace('Z', '+00:00'))
                if evt_time < cutoff:
                    continue
            events.append(event)
        except (json.JSONDecodeError, ValueError):
            continue

if len(events) < 3:
    sys.exit(0)

# 聚合指标
decisions = Counter(e.get('decision', 'unknown') for e in events)
hooks = Counter(e.get('hook', 'unknown') for e in events)
tools = Counter(e.get('tool', 'unknown') for e in events)

edited_files = Counter(
    e.get('detail', '').split()[-1] if e.get('detail') else ''
    for e in events if e.get('tool') == 'Edit' and e.get('detail')
)

durations = [e.get('duration_ms', 0) for e in events if e.get('duration_ms')]
avg_duration = sum(durations) // len(durations) if durations else 0

# --- 纠正信号检测 ---
correction_signals = []

# Signal 1: 高 warn 比率（>40% 的事件是 warn/block/escalate/correction）
total = len(events)
negative = decisions.get('warn', 0) + decisions.get('block', 0) + decisions.get('escalate', 0) + decisions.get('correction', 0)
warn_ratio = negative / total if total > 0 else 0
if warn_ratio > 0.4 and negative >= 5:
    correction_signals.append(f'高摩擦会话: {negative}/{total} 事件触发警告 ({warn_ratio:.0%})')

# Signal 2: 文件 churn（同文件 5+ 次编辑）
churn_files = [(f, c) for f, c in edited_files.most_common(3) if c >= 5 and f]
for f, c in churn_files:
    basename = os.path.basename(f)
    correction_signals.append(f'{basename} 编辑 {c} 次（反复修正）')

# Signal 3: correction 事件已存在（实时检测已触发）
correction_count = decisions.get('correction', 0)
if correction_count > 0:
    correction_signals.append(f'{correction_count} 次实时纠正检测触发')

# Signal 4: escalate 事件
escalate_count = decisions.get('escalate', 0)
if escalate_count > 0:
    correction_signals.append(f'{escalate_count} 次升级警告')

metrics = {
    'ts': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'session': '${VIBEGUARD_SESSION_ID}',
    'event_count': len(events),
    'decisions': dict(decisions),
    'hooks': dict(hooks),
    'tools': dict(tools),
    'top_edited_files': dict(edited_files.most_common(5)),
    'avg_duration_ms': avg_duration,
    'slow_ops': len([d for d in durations if d > 5000]),
    'correction_signals': correction_signals,
    'warn_ratio': round(warn_ratio, 2),
}

# 写入项目级指标文件
metrics_file = '${VIBEGUARD_PROJECT_LOG_DIR}/session-metrics.jsonl'
with open(metrics_file, 'a') as f:
    f.write(json.dumps(metrics, ensure_ascii=False) + '\n')

# 有纠正信号时输出建议
if correction_signals:
    print('LEARN_SUGGESTED')
    for sig in correction_signals:
        print(sig)
" 2>/dev/null || true)

# 如果检测到纠正信号，输出建议（不阻塞）
if [[ "$LEARN_SUGGESTION" == LEARN_SUGGESTED* ]]; then
  SIGNALS=$(echo "$LEARN_SUGGESTION" | tail -n +2)
  SIGNAL_COUNT=$(echo "$SIGNALS" | wc -l | tr -d ' ')

  # Stop hook 只支持顶层字段，不支持 hookSpecificOutput
  VG_SIGNALS="$SIGNALS" VG_COUNT="$SIGNAL_COUNT" python3 -c '
import json, os
signals = os.environ.get("VG_SIGNALS", "")
count = os.environ.get("VG_COUNT", "0")
signal_list = "; ".join(s for s in signals.strip().split("\n") if s)
msg = f"[VibeGuard 纠正检测] {count} 个信号: {signal_list}. 建议运行 /vibeguard:learn"
result = {"stopReason": msg}
print(json.dumps(result, ensure_ascii=False))
'
fi

# 清理本会话的 churn 标志文件
find "${HOME}/.vibeguard/" -name ".churn_warned_${VIBEGUARD_SESSION_ID}_*" -delete 2>/dev/null || true

exit 0

#!/usr/bin/env bash
# VibeGuard Session Metrics — Stop 事件指标采集
#
# 对标 Harness 反馈循环的数据采集层：
# 收集会话指标 → 写入项目级 metrics → 供 stats/gc/learn 消费
#
# 不做信号判断、不阻塞、不输出。纯采集。
set -euo pipefail
source "$(dirname "$0")/log.sh"

# 不在 git 仓库 → 跳过
if ! git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
  exit 0
fi

# 采集当前项目最近 30 分钟的会话指标
python3 -c "
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
}

# 写入项目级指标文件
metrics_file = '${VIBEGUARD_PROJECT_LOG_DIR}/session-metrics.jsonl'
with open(metrics_file, 'a') as f:
    f.write(json.dumps(metrics, ensure_ascii=False) + '\n')
" 2>/dev/null || true

exit 0

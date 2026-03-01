#!/usr/bin/env bash
# VibeGuard Learn Evaluator — Stop 事件主动评估 + 自动 Skill 草拟
#
# 会话结束时深度分析 events.jsonl，识别可提取的经验。
# 如果发现值得提取的模式，自动草拟 Skill 大纲并门禁暂停（exit 2）。
# 第二次触发时放行（防无限循环）。
#
# 触发条件：Stop 事件（full profile）
# exit 0 = 放行
# exit 2 = 门禁暂停，stdout 作为反馈
set -euo pipefail
source "$(dirname "$0")/log.sh"

FLAG_FILE="${HOME}/.vibeguard/.learn_eval_active"

# 防无限循环：已触发过 → 直接放行
if [[ -f "$FLAG_FILE" ]]; then
  rm -f "$FLAG_FILE"
  vg_log "learn-evaluator" "Stop" "pass" "evaluator already triggered once" ""
  exit 0
fi

# 不在 git 仓库 → 放行
if ! git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
  exit 0
fi

# 深度分析本次会话事件
ANALYSIS=$(python3 -c "
import json, sys, os
from collections import defaultdict, Counter

log_file = '${VIBEGUARD_LOG_FILE}'
if not os.path.exists(log_file):
    sys.exit(0)

session_id = '${VIBEGUARD_SESSION_ID}'
events = []
with open(log_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
            if event.get('session') == session_id or not session_id:
                events.append(event)
        except json.JSONDecodeError:
            continue

# 取最近 100 条作为本次会话的事件
events = events[-100:]

if len(events) < 3:
    print('SKIP:session_too_short')
    sys.exit(0)

# 信号检测
signals = []

# 1. 重复 warn 模式（同一 reason 出现 3+ 次 → 值得提取规避方法）
warn_reasons = Counter(
    e.get('reason', '') for e in events
    if e.get('decision') == 'warn' and e.get('reason')
)
for reason, count in warn_reasons.most_common(3):
    if count >= 3:
        signals.append(f'REPEATED_WARN:{count}:{reason}')

# 2. block 后成功模式（被拦截后换了方法成功 → 绕过方案值得记录）
blocks = [e for e in events if e.get('decision') == 'block']
if blocks:
    for block in blocks:
        block_idx = events.index(block)
        # 后续有 pass 事件 → 说明找到了替代方案
        subsequent_passes = [
            e for e in events[block_idx+1:]
            if e.get('decision') == 'pass' and e.get('hook') == block.get('hook')
        ]
        if subsequent_passes:
            signals.append(f'BLOCK_THEN_PASS:{block.get(\"reason\", \"\")}')

# 3. 长耗时操作（duration_ms > 5000 → 可能涉及复杂调试）
slow_ops = [
    e for e in events
    if e.get('duration_ms', 0) > 5000
]
if slow_ops:
    signals.append(f'SLOW_OPS:{len(slow_ops)}')

# 4. 多次编辑同一文件（>5 次 → 可能在反复调试）
edit_files = Counter(
    e.get('detail', '').split()[-1] if e.get('detail') else ''
    for e in events
    if e.get('tool') == 'Edit' and e.get('detail')
)
for file, count in edit_files.most_common(3):
    if count >= 5 and file:
        signals.append(f'REPEATED_EDIT:{count}:{file}')

# 5. gate 事件（门禁触发 → 说明有边界情况需要记录）
gates = [e for e in events if e.get('decision') == 'gate']
if gates:
    signals.append(f'GATE_TRIGGERED:{len(gates)}')

if not signals:
    print('SKIP:no_signals')
    sys.exit(0)

# 输出信号
for s in signals:
    print(s)
" 2>/dev/null || echo "SKIP:analysis_error")

# 无值得提取的信号 → 放行
if echo "$ANALYSIS" | grep -q "^SKIP:"; then
  REASON=$(echo "$ANALYSIS" | head -1 | cut -d: -f2)
  vg_log "learn-evaluator" "Stop" "pass" "no extractable signals: ${REASON}" ""
  exit 0
fi

# 有信号 → 设置门禁标志 + 输出 Skill 草案
mkdir -p "$(dirname "$FLAG_FILE")"
touch "$FLAG_FILE"

SIGNAL_COUNT=$(echo "$ANALYSIS" | wc -l | tr -d ' ')
SIGNAL_SUMMARY=$(echo "$ANALYSIS" | head -5 | tr '\n' '; ')

vg_log "learn-evaluator" "Stop" "gate" "extractable signals found: ${SIGNAL_COUNT}" "$SIGNAL_SUMMARY"

cat << EOF
[VibeGuard Learn Evaluator] 检测到 ${SIGNAL_COUNT} 个可提取信号：

$(echo "$ANALYSIS" | while IFS=: read -r type rest; do
  case "$type" in
    REPEATED_WARN)  echo "  - 重复警告: ${rest}" ;;
    BLOCK_THEN_PASS) echo "  - 被拦截后找到替代方案: ${rest}" ;;
    SLOW_OPS)       echo "  - 慢操作 (>5s): ${rest} 次" ;;
    REPEATED_EDIT)  echo "  - 反复编辑: ${rest}" ;;
    GATE_TRIGGERED) echo "  - 门禁触发: ${rest} 次" ;;
    *)              echo "  - ${type}: ${rest}" ;;
  esac
done)

请运行 /vibeguard:learn extract 提取为 Skill 再结束会话。
或者如果没有值得提取的经验，再次尝试结束即可跳过。
EOF

exit 2

#!/usr/bin/env bash
# VibeGuard Learn Evaluator — Stop 事件自动评估
#
# 会话结束时注入提醒，让 Claude 评估本次会话是否产生了可提取的经验。
# 与 stop-guard.sh 协同工作：stop-guard 检查未提交变更，本脚本检查未提取知识。
#
# 触发条件：Stop 事件
# 输出：提醒文本（stdout），不阻止会话结束
# exit 0 = 放行（不阻止停止）
set -euo pipefail
source "$(dirname "$0")/log.sh"

# 统计本次会话的事件数量（粗略判断会话复杂度）
SESSION_EVENTS=0
if [[ -f "$VIBEGUARD_LOG_FILE" ]]; then
  SESSION_EVENTS=$(tail -50 "$VIBEGUARD_LOG_FILE" | grep -c '"decision"' 2>/dev/null || echo "0")
fi

# 简单会话（<3 个事件）→ 不提醒
if [[ "$SESSION_EVENTS" -lt 3 ]]; then
  exit 0
fi

vg_log "learn-evaluator" "Stop" "pass" "session evaluation reminder injected" "events=$SESSION_EVENTS"

cat << 'EOF'
[VibeGuard Learn] 会话结束前评估：
- 本次是否有非显而易见的调试/排查？
- 是否发现了可复用的解决方案？
- 是否遇到了误导性错误消息？
如果是，用 /vibeguard:learn extract 提取为 Skill 再结束。
EOF

exit 0

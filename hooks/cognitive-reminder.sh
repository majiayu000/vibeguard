#!/usr/bin/env bash
# Cognitive Growth Reminder — SessionStart 事件认知成长仪表盘
#
# 每次会话开始时读取本周认知追踪数据，输出简要提醒。
# 数据来源：~/.refine/growth-tracker.json
# 可选：refine CLI 确认观测数据可用
#
# exit 0 = 始终放行
set -euo pipefail

TRACKER_FILE="${HOME}/.refine/growth-tracker.json"

# ── 确保追踪文件存在 ──
if [[ ! -f "$TRACKER_FILE" ]]; then
  mkdir -p "${HOME}/.refine"
  WEEK_START=$(python3 -c "
from datetime import date, timedelta
today = date.today()
monday = today - timedelta(days=today.weekday())
print(monday.isoformat())
" 2>/dev/null || date +%Y-%m-%d)
  cat > "$TRACKER_FILE" <<INIT
{
  "week_start": "${WEEK_START}",
  "exploration_sessions": 0,
  "deep_inquiry_sessions": 0,
  "delegation_sessions": 0,
  "prediction_before_ask": 0,
  "total_sessions": 0
}
INIT
fi

# ── 周轮转：如果当前周一 > tracker 中的 week_start，重置计数器 ──
python3 -c "
import json, sys
from datetime import date, timedelta
from pathlib import Path

tracker_path = Path('${TRACKER_FILE}')
try:
    data = json.loads(tracker_path.read_text())
except (json.JSONDecodeError, FileNotFoundError):
    data = {}

today = date.today()
current_monday = today - timedelta(days=today.weekday())
week_start = data.get('week_start', '')

if week_start < current_monday.isoformat():
    # 保留上周数据作为 last_week
    data['last_week'] = {
        'exploration_sessions': data.get('exploration_sessions', 0),
        'deep_inquiry_sessions': data.get('deep_inquiry_sessions', 0),
        'delegation_sessions': data.get('delegation_sessions', 0),
        'prediction_before_ask': data.get('prediction_before_ask', 0),
        'total_sessions': data.get('total_sessions', 0),
    }
    data['week_start'] = current_monday.isoformat()
    data['exploration_sessions'] = 0
    data['deep_inquiry_sessions'] = 0
    data['delegation_sessions'] = 0
    data['prediction_before_ask'] = 0
    data['total_sessions'] = 0
    tracker_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + '\n')
" 2>/dev/null || true

# ── 检查 refine 是否可用（graceful fallback） ──
HAS_REFINE=false
if command -v refine &>/dev/null; then
  if refine list --type observation --limit 1 &>/dev/null 2>&1; then
    HAS_REFINE=true
  fi
fi

# ── 生成仪表盘输出 ──
DASHBOARD=$(HAS_REFINE="$HAS_REFINE" python3 -c "
import json, os, sys
from datetime import date, timedelta
from pathlib import Path

tracker_path = Path('${TRACKER_FILE}')
try:
    data = json.loads(tracker_path.read_text())
except (json.JSONDecodeError, FileNotFoundError):
    print('认知追踪文件读取失败')
    sys.exit(0)

total = data.get('total_sessions', 0)
exploration = data.get('exploration_sessions', 0)
deep_inquiry = data.get('deep_inquiry_sessions', 0)
delegation = data.get('delegation_sessions', 0)
prediction = data.get('prediction_before_ask', 0)

# 上周探索率
last_week = data.get('last_week', {})
lw_total = last_week.get('total_sessions', 0)
lw_exploration = last_week.get('exploration_sessions', 0)
if lw_total > 0:
    lw_rate = f'{lw_exploration}/{lw_total} ({lw_exploration * 100 // lw_total}%)'
else:
    lw_rate = '无数据'

lines = []
lines.append('认知成长仪表盘')
lines.append(f'探索率: {exploration}/1 本周目标 (上周: {lw_rate})')

# 协作模式
modes = []
if delegation > 0:
    modes.append(f'delegation {delegation}次')
if deep_inquiry > 0:
    modes.append(f'deep_inquiry {deep_inquiry}次')
if exploration > 0:
    modes.append(f'exploration {exploration}次')
if modes:
    lines.append(f'协作模式: {\" | \".join(modes)}')
else:
    lines.append(f'协作模式: 本周尚无记录 (共 {total} 次会话)')

lines.append('提醒: 开始前先写下你的预测（根因、路径、风险）再让 AI 回应')

# 周一第一个 session 额外提醒
today = date.today()
if today.weekday() == 0 and total == 0:
    lines.append('本周第一个会话! 建议先运行 refine insights 查看上周报告')

# refine 不可用时提示
has_refine = os.environ.get('HAS_REFINE', 'false')
if has_refine != 'true':
    lines.append('(refine CLI 不可用，认知观测数据未加载)')

print('\n'.join(lines))
" 2>/dev/null || echo "认知提醒加载失败（python3 不可用）")

# ── 输出 hookSpecificOutput ──
if [[ -n "$DASHBOARD" ]]; then
  VG_DASHBOARD="$DASHBOARD" python3 -c '
import json, os
dashboard = os.environ.get("VG_DASHBOARD", "")
output = {
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": dashboard
    }
}
print(json.dumps(output, ensure_ascii=False))
'
fi

exit 0

#!/usr/bin/env bash
# Cognitive Growth Reminder — SessionStart 事件认知成长仪表盘
#
# 每次会话开始时从真实数据源统计本周认知数据：
# 1. JSONL 文件数 = 真实 session 数
# 2. refine DB = 已 ingest 的协作模式分布
#
# exit 0 = 始终放行
set -euo pipefail

TRACKER_FILE="${HOME}/.refine/growth-tracker.json"

# ── 确保追踪文件存在 ──
mkdir -p "${HOME}/.refine"
if [[ ! -f "$TRACKER_FILE" ]]; then
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
  "total_sessions": 0
}
INIT
fi

# ── 周轮转 + 从真实数据源统计 ──
python3 << 'PYEOF' 2>/dev/null || true
import json, subprocess, os
from datetime import date, timedelta
from pathlib import Path

tracker_path = Path(os.path.expanduser("~/.refine/growth-tracker.json"))
db_path = os.path.expanduser("~/Library/Application Support/refine/refine.db")

try:
    data = json.loads(tracker_path.read_text())
except (json.JSONDecodeError, FileNotFoundError):
    data = {}

today = date.today()
monday = today - timedelta(days=today.weekday())
monday_str = monday.isoformat()
week_start = data.get("week_start", "")

# Week rotation
if week_start < monday_str:
    data["last_week"] = {
        "exploration_sessions": data.get("exploration_sessions", 0),
        "deep_inquiry_sessions": data.get("deep_inquiry_sessions", 0),
        "delegation_sessions": data.get("delegation_sessions", 0),
        "total_sessions": data.get("total_sessions", 0),
    }
    data["week_start"] = monday_str

# Count real JSONL files modified this week
projects_dir = Path.home() / ".claude" / "projects"
total = 0
if projects_dir.exists():
    for project_dir in projects_dir.iterdir():
        if not project_dir.is_dir():
            continue
        dirs_to_scan = [project_dir]
        for sub in project_dir.iterdir():
            if sub.is_dir() and sub.name != "subagents":
                dirs_to_scan.append(sub)
        for scan_dir in dirs_to_scan:
            for f in scan_dir.glob("*.jsonl"):
                if f.name.startswith("agent-"):
                    continue
                mtime = date.fromtimestamp(f.stat().st_mtime)
                if mtime >= monday:
                    total += 1

data["total_sessions"] = total

# Query DB for collaboration modes
if Path(db_path).exists():
    try:
        sql = (
            "SELECT je.value, COUNT(DISTINCT items.document_id) "
            "FROM items, json_each(items.tags) je "
            "WHERE item_type='observation' AND length(content) > 200 "
            f"AND created_at >= '{monday_str}T00:00:00' "
            "AND je.value IN ('exploration','deep_inquiry','delegation',"
            "'pair_programming','review','teaching','debugging') "
            "GROUP BY je.value"
        )
        result = subprocess.run(
            ["sqlite3", db_path, sql],
            capture_output=True, text=True, timeout=5
        )
        modes = {}
        for line in result.stdout.strip().split("\n"):
            if "|" in line:
                mode, count = line.split("|")
                modes[mode] = int(count)
        data["exploration_sessions"] = modes.get("exploration", 0)
        data["deep_inquiry_sessions"] = modes.get("deep_inquiry", 0)
        data["delegation_sessions"] = modes.get("delegation", 0)
    except Exception:
        pass

tracker_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PYEOF

# ── 生成仪表盘输出 ──
DASHBOARD=$(python3 << 'PYEOF' 2>/dev/null || echo "认知提醒加载失败"
import json, os
from pathlib import Path

tracker_path = Path(os.path.expanduser("~/.refine/growth-tracker.json"))
try:
    data = json.loads(tracker_path.read_text())
except (json.JSONDecodeError, FileNotFoundError):
    print("认知追踪文件读取失败")
    exit(0)

total = data.get("total_sessions", 0)
exploration = data.get("exploration_sessions", 0)
deep_inquiry = data.get("deep_inquiry_sessions", 0)
delegation = data.get("delegation_sessions", 0)
ingested = exploration + deep_inquiry + delegation

last_week = data.get("last_week", {})
lw_total = last_week.get("total_sessions", 0)
lw_exploration = last_week.get("exploration_sessions", 0)
if lw_total > 0:
    lw_rate = f"{lw_exploration}/{lw_total} ({lw_exploration * 100 // lw_total}%)"
else:
    lw_rate = "无数据"

lines = []
lines.append("认知成长仪表盘")
lines.append(f"本周 {total} 个 session (已分析 {ingested}) | 探索: {exploration} (上周: {lw_rate})")

modes = []
if delegation > 0:
    modes.append(f"delegation {delegation}")
if deep_inquiry > 0:
    modes.append(f"deep_inquiry {deep_inquiry}")
if exploration > 0:
    modes.append(f"exploration {exploration}")
if modes:
    lines.append(f"协作模式: {' | '.join(modes)}")

if total > ingested + 5:
    lines.append(f"提示: 有 {total - ingested} 个 session 未分析，运行 refine ingest-sessions")

# Read LLM advice from mirror cache
advice_path = Path(os.path.expanduser("~/.mirror/advice.json"))
try:
    advice_data = json.loads(advice_path.read_text())
    advice = advice_data.get("advice", "")
    if advice:
        lines.append(f"建议: {advice}")
    else:
        lines.append("提醒: 开始前先写下你的预测（根因、路径、风险）再让 AI 回应")
except (json.JSONDecodeError, FileNotFoundError):
    lines.append("提醒: 开始前先写下你的预测（根因、路径、风险）再让 AI 回应")

print("\n".join(lines))
PYEOF
)

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

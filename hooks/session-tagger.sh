#!/usr/bin/env bash
# Session Tagger — Stop 事件：从真实数据源更新 growth-tracker.json
#
# 不再简单 +1，而是：
# 1. 从 ~/.claude/projects/ 统计本周实际 JSONL 文件数（真实 session 数）
# 2. 从 refine DB 统计本周已 ingest 的协作模式分布
#
# exit 0 = 始终放行
set -euo pipefail

TRACKER_FILE="${HOME}/.refine/growth-tracker.json"
DB_PATH="${HOME}/Library/Application Support/refine/refine.db"

if [[ ! -f "$TRACKER_FILE" ]]; then
  exit 0
fi

python3 << 'PYEOF' 2>/dev/null || true
import json, subprocess, os
from datetime import date, timedelta
from pathlib import Path

tracker_path = Path(os.path.expanduser("~/.refine/growth-tracker.json"))
db_path = os.path.expanduser("~/Library/Application Support/refine/refine.db")

try:
    data = json.loads(tracker_path.read_text())
except (json.JSONDecodeError, FileNotFoundError):
    exit(0)

today = date.today()
monday = today - timedelta(days=today.weekday())
monday_str = monday.isoformat()

# 1. Count real JSONL files modified this week (excluding subagents)
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

# 2. Query DB for this week's collaboration modes
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

exit 0

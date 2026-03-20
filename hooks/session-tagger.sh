#!/usr/bin/env bash
# Session Tagger — Stop 事件会话计数器
#
# 会话结束时递增 ~/.refine/growth-tracker.json 中的 total_sessions。
# 实际的协作模式标记由 refine ingest-sessions 处理。
#
# exit 0 = 始终放行
set -euo pipefail

TRACKER_FILE="${HOME}/.refine/growth-tracker.json"

# 追踪文件不存在则跳过（cognitive-reminder 会在下次 SessionStart 创建）
if [[ ! -f "$TRACKER_FILE" ]]; then
  exit 0
fi

# 原子递增 total_sessions
python3 -c "
import json
from pathlib import Path

tracker_path = Path('${TRACKER_FILE}')
try:
    data = json.loads(tracker_path.read_text())
except (json.JSONDecodeError, FileNotFoundError):
    exit(0)

data['total_sessions'] = data.get('total_sessions', 0) + 1
tracker_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + '\n')
" 2>/dev/null || true

exit 0

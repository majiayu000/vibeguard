#!/usr/bin/env bash
# VibeGuard PreToolUse(Write) Hook
# 当 AI 尝试创建新文件时，注入提醒上下文
# 如果文件已存在（编辑），不干扰

set -euo pipefail

# 从 stdin 读取 JSON
INPUT=$(cat)

# 提取 file_path（使用 python3 解析 JSON，避免依赖 jq）
FILE_PATH=$(echo "$INPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('tool_input', {}).get('file_path', ''))
" 2>/dev/null || echo "")

# 如果无法解析或文件已存在，直接退出不干扰
if [[ -z "$FILE_PATH" ]] || [[ -e "$FILE_PATH" ]]; then
  exit 0
fi

# 新文件：输出提醒上下文
cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "VIBEGUARD 提醒：你正在创建新文件。请确认已调用 mcp__vibeguard__guard_check(guard=duplicates) 检查是否已有类似实现。如未检查，请先调用检查再创建。"
  }
}
EOF

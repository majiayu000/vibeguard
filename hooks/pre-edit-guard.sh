#!/usr/bin/env bash
# VibeGuard PreToolUse(Edit) Hook
#
# 编辑文件前的防幻觉检查：
#   - 检测编辑的文件是否存在（防止 AI 编辑不存在的文件路径）
#   - 检测 old_string 是否真的在文件中（防止 AI 幻觉编辑内容）

set -euo pipefail

source "$(dirname "$0")/log.sh"

INPUT=$(cat)

RESULT=$(echo "$INPUT" | vg_json_two_fields "tool_input.file_path" "tool_input.old_string")

FILE_PATH=$(echo "$RESULT" | head -1)
OLD_STRING=$(echo "$RESULT" | tail -n +2)

if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

# 检查文件是否存在
if [[ ! -f "$FILE_PATH" ]]; then
  vg_log "pre-edit-guard" "Edit" "block" "文件不存在" "$FILE_PATH"
  cat <<BLOCK_EOF
{
  "decision": "block",
  "reason": "VIBEGUARD 拦截：文件不存在 — ${FILE_PATH}。AI 可能幻觉了文件路径。请先用 Glob/Grep 搜索正确的文件路径。"
}
BLOCK_EOF
  exit 0
fi

# 检查 old_string 是否在文件中（仅当 old_string 非空时）
if [[ -n "$OLD_STRING" ]]; then
  if ! VG_FILE_PATH="$FILE_PATH" python3 -c '
import sys, os
with open(os.environ["VG_FILE_PATH"], "r") as f:
    content = f.read()
old = sys.stdin.read()
sys.exit(0 if old in content else 1)
' <<< "$OLD_STRING" 2>/dev/null; then
    vg_log "pre-edit-guard" "Edit" "block" "old_string 不存在" "$FILE_PATH"
    cat <<BLOCK_EOF
{
  "decision": "block",
  "reason": "VIBEGUARD 拦截：old_string 在文件中不存在 — AI 可能幻觉了文件内容。请先用 Read 工具读取文件，确认要替换的内容确实存在。"
}
BLOCK_EOF
    exit 0
  fi
fi

# 通过所有检查 → 放行
vg_log "pre-edit-guard" "Edit" "pass" "" "$FILE_PATH"
exit 0

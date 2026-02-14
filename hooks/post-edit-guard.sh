#!/usr/bin/env bash
# VibeGuard PostToolUse(Edit) Hook
#
# 编辑源码后检测是否引入了质量问题：
#   - Rust: 新增 unwrap()/expect() 到非测试代码
#   - 通用: 新增硬编码路径 (.db/.sqlite)
#
# 输出警告上下文，不阻止操作（事后提醒）

set -euo pipefail

INPUT=$(cat)

RESULT=$(echo "$INPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
tool_input = data.get('tool_input', {})
file_path = tool_input.get('file_path', '')
new_string = tool_input.get('new_string', '')
print(file_path)
print('---SEPARATOR---')
print(new_string)
" 2>/dev/null || echo "")

FILE_PATH=$(echo "$RESULT" | head -1)
NEW_STRING=$(echo "$RESULT" | sed '1,/---SEPARATOR---/d')

if [[ -z "$FILE_PATH" ]] || [[ -z "$NEW_STRING" ]]; then
  exit 0
fi

WARNINGS=""

# --- Rust 检查 ---
if [[ "$FILE_PATH" == *.rs ]]; then
  # 排除测试文件
  case "$FILE_PATH" in
    */tests/*|*_test.rs|*/test_*) ;;
    *)
      # 检测新增的 unwrap()/expect()
      if echo "$NEW_STRING" | grep -qE '\.(unwrap|expect)\(' 2>/dev/null; then
        # 排除安全变体
        UNSAFE_COUNT=$(echo "$NEW_STRING" | grep -cE '\.(unwrap|expect)\(' 2>/dev/null || echo 0)
        SAFE_COUNT=$(echo "$NEW_STRING" | grep -cE '\.(unwrap_or|unwrap_or_else|unwrap_or_default)\(' 2>/dev/null || echo 0)
        REAL_COUNT=$((UNSAFE_COUNT - SAFE_COUNT))
        if [[ $REAL_COUNT -gt 0 ]]; then
          WARNINGS="${WARNINGS}[RS-03] 新增了 ${REAL_COUNT} 个 unwrap()/expect()，建议使用 ? 或 map_err 替代。"
        fi
      fi
      ;;
  esac
fi

# --- 通用检查：硬编码数据库路径 ---
if echo "$NEW_STRING" | grep -qE '"[^"]*\.(db|sqlite)"' 2>/dev/null; then
  case "$FILE_PATH" in
    */tests/*|*_test.*|*.test.*|*.spec.*) ;;
    *)
      WARNINGS="${WARNINGS:+${WARNINGS} }[U-11] 检测到硬编码数据库路径，建议使用配置或公共函数。"
      ;;
  esac
fi

if [[ -z "$WARNINGS" ]]; then
  exit 0
fi

# 输出警告
python3 -c "
import json
warnings = '''$WARNINGS'''
result = {
    'hookSpecificOutput': {
        'hookEventName': 'PostToolUse',
        'additionalContext': 'VIBEGUARD 质量警告：' + warnings
    }
}
print(json.dumps(result, ensure_ascii=False))
"

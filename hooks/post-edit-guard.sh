#!/usr/bin/env bash
# VibeGuard PostToolUse(Edit) Hook
#
# 编辑源码后检测是否引入了质量问题：
#   - Rust: 新增 unwrap()/expect() 到非测试代码
#   - 通用: 新增硬编码路径 (.db/.sqlite)
#
# 输出警告上下文，不阻止操作（事后提醒）

set -euo pipefail

source "$(dirname "$0")/log.sh"

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
          WARNINGS="${WARNINGS}[RS-03] 新增了 ${REAL_COUNT} 个 unwrap()/expect()。修复：将 .unwrap() 替换为 .map_err(|e| YourError::from(e))? 或 .unwrap_or_default()；在 main() 入口可用 anyhow::Result<()>。参考模式见 vibeguard/workflows/auto-optimize/rules/rust.md RS-03。"
        fi
      fi
      ;;
  esac
fi

# --- JavaScript/TypeScript 检查：console.log/warn/error ---
case "$FILE_PATH" in
  *.ts|*.tsx|*.js|*.jsx)
    case "$FILE_PATH" in
      */tests/*|*_test.*|*.test.*|*.spec.*) ;;
      *)
        CONSOLE_COUNT=$(echo "$NEW_STRING" | grep -cE '\bconsole\.(log|warn|error)\(' 2>/dev/null || echo 0)
        if [[ $CONSOLE_COUNT -gt 0 ]]; then
          WARNINGS="${WARNINGS:+${WARNINGS} }[DEBUG] 新增了 ${CONSOLE_COUNT} 个 console.log/warn/error。修复：使用项目的 logger 替代 console 调用；如果是临时调试，完成后删除。"
        fi
        ;;
    esac
    ;;
esac

# --- Python 检查：print() 语句 ---
case "$FILE_PATH" in
  *.py)
    case "$FILE_PATH" in
      */tests/*|*test_*|*_test.py) ;;
      *)
        PRINT_COUNT=$(echo "$NEW_STRING" | grep -cE '^\s*print\(' 2>/dev/null || echo 0)
        if [[ $PRINT_COUNT -gt 0 ]]; then
          WARNINGS="${WARNINGS:+${WARNINGS} }[DEBUG] 新增了 ${PRINT_COUNT} 个 print() 语句。修复：使用 logging 模块替代 print；如果是临时调试，完成后删除。"
        fi
        ;;
    esac
    ;;
esac

# --- 通用检查：硬编码数据库路径 ---
if echo "$NEW_STRING" | grep -qE '"[^"]*\.(db|sqlite)"' 2>/dev/null; then
  case "$FILE_PATH" in
    */tests/*|*_test.*|*.test.*|*.spec.*) ;;
    *)
      WARNINGS="${WARNINGS:+${WARNINGS} }[U-11] 检测到硬编码数据库路径。修复：将路径提取到 core 层公共函数（如 default_db_path()），所有入口统一调用；环境变量覆盖用 env::var(\"APP_DB_PATH\").unwrap_or_else(|_| default_db_path())。参考 vibeguard/workflows/auto-optimize/rules/universal.md U-11。"
      ;;
  esac
fi

if [[ -z "$WARNINGS" ]]; then
  vg_log "post-edit-guard" "Edit" "pass" "" "$FILE_PATH"
  exit 0
fi

vg_log "post-edit-guard" "Edit" "warn" "$WARNINGS" "$FILE_PATH"

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

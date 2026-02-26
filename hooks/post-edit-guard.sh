#!/usr/bin/env bash
# VibeGuard PostToolUse(Edit) Hook
#
# 编辑源码后检测是否引入了质量问题：
#   - Rust: 新增 unwrap()/expect() 到非测试代码
#   - Rust: 新增 let _ = 静默丢弃 Result
#   - 通用: 新增硬编码路径 (.db/.sqlite)
#
# 输出警告上下文，不阻止操作（事后提醒）

set -euo pipefail

source "$(dirname "$0")/log.sh"

INPUT=$(cat)

RESULT=$(echo "$INPUT" | vg_json_two_fields "tool_input.file_path" "tool_input.new_string")

FILE_PATH=$(echo "$RESULT" | head -1)
NEW_STRING=$(echo "$RESULT" | tail -n +2)

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
      # [RS-03] 检测新增的 unwrap()/expect()
      if echo "$NEW_STRING" | grep -qE '\.(unwrap|expect)\(' 2>/dev/null; then
        # 排除安全变体
        UNSAFE_COUNT=$(echo "$NEW_STRING" | grep -cE '\.(unwrap|expect)\(' 2>/dev/null || true)
        SAFE_COUNT=$(echo "$NEW_STRING" | grep -cE '\.(unwrap_or|unwrap_or_else|unwrap_or_default)\(' 2>/dev/null || true)
        REAL_COUNT=$((UNSAFE_COUNT - SAFE_COUNT))
        if [[ $REAL_COUNT -gt 0 ]]; then
          WARNINGS="${WARNINGS}[RS-03] 新增了 ${REAL_COUNT} 个 unwrap()/expect()。修复：将 .unwrap() 替换为 .map_err(|e| YourError::from(e))? 或 .unwrap_or_default()；在 main() 入口可用 anyhow::Result<()>。参考模式见 vibeguard/rules/rust.md RS-03。"
        fi
      fi
      # [RS-10] 检测静默丢弃 Result（let _ = expr）
      SILENT_COUNT=$(echo "$NEW_STRING" | grep -cE '^\s*let\s+_\s*=' 2>/dev/null; true)
      if [[ $SILENT_COUNT -gt 0 ]]; then
        WARNINGS="${WARNINGS:+${WARNINGS} }[RS-10] 新增了 ${SILENT_COUNT} 个 let _ = 静默丢弃。修复：用 if let Err(e) = expr { log::warn(...) } 记录错误，或用 .map_err() 传播。参考 vibeguard/rules/rust.md RS-10。"
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
        CONSOLE_COUNT=$(echo "$NEW_STRING" | grep -cE '\bconsole\.(log|warn|error)\(' 2>/dev/null; true)
        if [[ $CONSOLE_COUNT -gt 0 ]]; then
          WARNINGS="${WARNINGS:+${WARNINGS} }[DEBUG] 新增了 ${CONSOLE_COUNT} 个 console.log/warn/error。修复：使用项目的 logger 替代 console 调用；如果是临时调试，完成后删除。"
        fi

        # [U-HARDCODE] 检测硬编码默认值（字符串字面量作为 prop/参数默认值）
        HARDCODE_HITS=$(echo "$NEW_STRING" | grep -cE "=\s*['\"][A-Z][A-Za-z]+['\"]" 2>/dev/null; true)
        if [[ $HARDCODE_HITS -gt 0 ]]; then
          # 排除合理的默认值（空字符串、类型标注、常量定义）
          REAL_HITS=$(echo "$NEW_STRING" | grep -E "=\s*['\"][A-Z][A-Za-z]+['\"]" 2>/dev/null \
            | grep -cvE "(export const|type |interface |import |from |===|!==|==|case )" 2>/dev/null; true)
          if [[ $REAL_HITS -gt 0 ]]; then
            WARNINGS="${WARNINGS:+${WARNINGS} }[U-HARDCODE] 检测到 ${REAL_HITS} 处疑似硬编码默认值（如 userName='BOB'）。修复：默认值应为空字符串或从 context/props 获取真实数据，不要用假数据占位。"
          fi
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
        PRINT_COUNT=$(echo "$NEW_STRING" | grep -cE '^\s*print\(' 2>/dev/null; true)
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
      WARNINGS="${WARNINGS:+${WARNINGS} }[U-11] 检测到硬编码数据库路径。修复：将路径提取到 core 层公共函数（如 default_db_path()），所有入口统一调用；环境变量覆盖用 env::var(\"APP_DB_PATH\").unwrap_or_else(|_| default_db_path())。参考 vibeguard/rules/universal.md U-11。"
      ;;
  esac
fi

if [[ -z "$WARNINGS" ]]; then
  vg_log "post-edit-guard" "Edit" "pass" "" "$FILE_PATH"
  exit 0
fi

# --- Escalation 检测 ---
# 同一文件在当前日志中被 warn 3 次以上 → 升级为 escalate
DECISION="warn"
WARN_COUNT_FOR_FILE=$(VG_LOG_FILE="$VIBEGUARD_LOG_FILE" VG_FILE_PATH="$FILE_PATH" python3 -c '
import json, os
log_file = os.environ.get("VG_LOG_FILE", "")
file_path = os.environ.get("VG_FILE_PATH", "")
count = 0
try:
    with open(log_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
                if e.get("hook") == "post-edit-guard" and e.get("decision") == "warn" and file_path in e.get("detail", ""):
                    count += 1
            except (json.JSONDecodeError, KeyError):
                continue
except FileNotFoundError:
    pass
print(count)
' 2>/dev/null | tr -d '[:space:]' || echo "0")
WARN_COUNT_FOR_FILE="${WARN_COUNT_FOR_FILE:-0}"

if [[ "$WARN_COUNT_FOR_FILE" -ge 3 ]]; then
  DECISION="escalate"
  WARNINGS="[ESCALATE] 该文件已被警告 ${WARN_COUNT_FOR_FILE} 次，建议用户主动介入审查。${WARNINGS}"
fi

vg_log "post-edit-guard" "Edit" "$DECISION" "$WARNINGS" "$FILE_PATH"

# 输出警告（通过环境变量传参，避免注入）
VG_WARNINGS="$WARNINGS" VG_DECISION="$DECISION" python3 -c '
import json, os
warnings = os.environ.get("VG_WARNINGS", "")
decision = os.environ.get("VG_DECISION", "warn")
prefix = "VIBEGUARD 升级警告" if decision == "escalate" else "VIBEGUARD 质量警告"
result = {
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": prefix + "：" + warnings
    }
}
print(json.dumps(result, ensure_ascii=False))
'

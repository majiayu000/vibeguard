#!/usr/bin/env bash
# VibeGuard PostToolUse(Edit) Hook
#
# 编辑源码后检测是否引入了质量问题：
#   - Rust: 新增 unwrap()/expect() 到非测试代码
#   - Rust: 新增 let _ = 静默丢弃 Result
#   - 通用: 新增硬编码路径 (.db/.sqlite)
#
# 输出警告上下文，不阻止操作（事后提醒）
#
# 抑制单行警告：在被检测行的上一行添加：
#   // vibeguard-disable-next-line RS-03 -- reason   (Rust/TS/JS/Go)
#   # vibeguard-disable-next-line RS-03 -- reason    (Python/Shell)

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

# ---------------------------------------------------------------------------
# vg_filter_suppressed RULE_ID
# Reads NEW_STRING from stdin; outputs lines NOT suppressed by the rule.
# Suppression: a line is suppressed when the immediately preceding line
# contains "vibeguard-disable-next-line RULE_ID" (any comment prefix).
# ---------------------------------------------------------------------------
vg_filter_suppressed() {
  local rule="$1"
  python3 -c "
import sys, re
rule = sys.argv[1]
suppress_pat = re.compile(r'^\s*(?://|#)\s*vibeguard-disable-next-line\s+' + re.escape(rule) + r'(?:\s|--|$)')

def _in_multiline_string(lines, idx):
    # Count triple-quote delimiters before this line; odd count means we are inside one.
    text_before = '\n'.join(lines[:idx])
    return (text_before.count('\"\"\"') % 2 == 1) or (text_before.count(\"'''\") % 2 == 1)

lines = sys.stdin.read().splitlines()
for i, line in enumerate(lines):
    prev = lines[i - 1] if i > 0 else ''
    if suppress_pat.search(prev) and not _in_multiline_string(lines, i - 1):
        continue
    print(line)
" "$rule"
}

# --- Rust 检查 ---
if [[ "$FILE_PATH" == *.rs ]]; then
  # 排除测试文件
  case "$FILE_PATH" in
    */tests/*|*_test.rs|*/test_*) ;;
    *)
      # [RS-03] 检测新增的 unwrap()/expect()
      _RS03_FILTERED=$(echo "$NEW_STRING" | vg_filter_suppressed "RS-03")
      if echo "$_RS03_FILTERED" | grep -qE '\.(unwrap|expect)\(' 2>/dev/null; then
        # 排除安全变体
        UNSAFE_COUNT=$(echo "$_RS03_FILTERED" | grep -cE '\.(unwrap|expect)\(' 2>/dev/null || true)
        SAFE_COUNT=$(echo "$_RS03_FILTERED" | grep -cE '\.(unwrap_or|unwrap_or_else|unwrap_or_default)\(' 2>/dev/null || true)
        REAL_COUNT=$((UNSAFE_COUNT - SAFE_COUNT))
        if [[ $REAL_COUNT -gt 0 ]]; then
          WARNINGS="${WARNINGS}[RS-03] 新增了 ${REAL_COUNT} 个 unwrap()/expect()。修复：将 .unwrap() 替换为 .map_err(|e| YourError::from(e))? 或 .unwrap_or_default()；在 main() 入口可用 anyhow::Result<()>。立即修复，不要留到后面。参考 vibeguard/rules/rust.md RS-03。"
        fi
      fi
      # [RS-10] 检测静默丢弃 Result（let _ = expr）
      SILENT_COUNT=$(echo "$NEW_STRING" | vg_filter_suppressed "RS-10" | grep -cE '^\s*let\s+_\s*=' 2>/dev/null; true)
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
      */debug.*|*/debug/*|*logger*|*logging*) ;;
      *)
        # CLI 项目允许 console，跳过（bin 字段 / src/cli.* / scripts 含 cli）
        _PKG_DIR=$(dirname "$FILE_PATH")
        _IS_CLI=false
        while [[ "$_PKG_DIR" != "/" ]]; do
          if [[ -f "$_PKG_DIR/package.json" ]]; then
            grep -qE '"bin"' "$_PKG_DIR/package.json" 2>/dev/null && _IS_CLI=true
            grep -qE '"[^"]*":\s*"[^"]*cli[^"]*"' "$_PKG_DIR/package.json" 2>/dev/null && _IS_CLI=true
          fi
          ls "$_PKG_DIR/src/cli."* "$_PKG_DIR/cli."* 2>/dev/null | grep -q . && _IS_CLI=true
          [[ "$_IS_CLI" == true ]] && break
          _PKG_DIR=$(dirname "$_PKG_DIR")
        done
        # MCP 入口文件用 console.error 输出到 stderr 是协议标准做法，跳过
        if [[ "$_IS_CLI" == true ]]; then
          : # CLI 项目，console 为正常输出方式
        elif [[ -f "$FILE_PATH" ]] && grep -qE '(StdioServerTransport|new Server\(|McpServer)' "$FILE_PATH" 2>/dev/null; then
          : # MCP 入口文件，跳过 console 检测
        else
          CONSOLE_COUNT=$(echo "$NEW_STRING" | vg_filter_suppressed "DEBUG" | grep -cE '\bconsole\.(log|warn|error)\(' 2>/dev/null; true)
          if [[ $CONSOLE_COUNT -gt 0 ]]; then
            # 检查文件中已有的 console 残留总数
            FILE_CONSOLE_TOTAL=0
            if [[ -f "$FILE_PATH" ]]; then
              FILE_CONSOLE_TOTAL=$(grep -cE '\bconsole\.(log|warn|error)\(' "$FILE_PATH" 2>/dev/null; true)
            fi
            if [[ $FILE_CONSOLE_TOTAL -ge 10 ]]; then
              WARNINGS="${WARNINGS:+${WARNINGS} }[DEBUG ESCALATE] 文件已有 ${FILE_CONSOLE_TOTAL} 处 console 残留，且仍在新增！必须立即清理：使用项目 logger 替代所有 console 调用。"
            else
              WARNINGS="${WARNINGS:+${WARNINGS} }[DEBUG] 新增了 ${CONSOLE_COUNT} 个 console.log/warn/error。修复：使用项目的 logger 替代 console 调用；如果是临时调试，完成后删除。"
            fi
          fi
        fi

        # [U-HARDCODE] 已移除：信噪比过低，枚举赋值/React props/常量定义全误报
        # 详见 docs/known-false-positives.md#U-HARDCODE
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
        PRINT_COUNT=$(echo "$NEW_STRING" | vg_filter_suppressed "DEBUG" | grep -cE '^\s*print\(' 2>/dev/null; true)
        if [[ $PRINT_COUNT -gt 0 ]]; then
          WARNINGS="${WARNINGS:+${WARNINGS} }[DEBUG] 新增了 ${PRINT_COUNT} 个 print() 语句。修复：使用 logging 模块替代 print；如果是临时调试，完成后删除。"
        fi
        ;;
    esac
    ;;
esac

# --- 通用检查：硬编码数据库路径 ---
if echo "$NEW_STRING" | vg_filter_suppressed "U-11" | grep -qE '"[^"]*\.(db|sqlite)"' 2>/dev/null; then
  case "$FILE_PATH" in
    */tests/*|*_test.*|*.test.*|*.spec.*) ;;
    *)
      WARNINGS="${WARNINGS:+${WARNINGS} }[U-11] 检测到硬编码数据库路径。修复：将路径提取到 core 层公共函数（如 default_db_path()），所有入口统一调用；环境变量覆盖用 env::var(\"APP_DB_PATH\").unwrap_or_else(|_| default_db_path())。参考 vibeguard/rules/universal.md U-11。"
      ;;
  esac
fi

# --- Go 检查 ---
case "$FILE_PATH" in
  *.go)
    case "$FILE_PATH" in
      *_test.go|*/vendor/*) ;;
      *)
        # [GO-01] 检测 error 丢弃（排除 for range 和 map 查找）
        ERR_DISCARD=$(echo "$NEW_STRING" | vg_filter_suppressed "GO-01" | grep -E '^\s*_\s*(,\s*_)?\s*[:=]+' 2>/dev/null \
          | grep -cvE '(for\s+.*range|,\s*(ok|found|exists)\s*:?=)' 2>/dev/null; true)
        if [[ $ERR_DISCARD -gt 0 ]]; then
          WARNINGS="${WARNINGS:+${WARNINGS} }[GO-01] 新增了 ${ERR_DISCARD} 处 error 丢弃（_ = ...）。修复：用 if err != nil 处理错误。"
        fi
        # [GO-08] 检测 defer 在循环内
        DEFER_LOOP=$(echo "$NEW_STRING" | vg_filter_suppressed "GO-08" | awk '/^\s*for\s/ {in_loop=1} /^\s*defer\s/ && in_loop {count++} /^\s*\}/ {in_loop=0} END {print count+0}' 2>/dev/null; true)
        DEFER_LOOP="${DEFER_LOOP:-0}"
        if [[ $DEFER_LOOP -gt 0 ]]; then
          WARNINGS="${WARNINGS:+${WARNINGS} }[GO-08] 检测到 defer 在循环内，可能导致资源泄漏。修复：将 defer 所在逻辑提取为独立函数。"
        fi
        ;;
    esac
    ;;
esac

# --- Anti-Stub 检测（GSD 借鉴：三级制品验证 Level 2 — Substantiveness） ---
STUB_WARNINGS=""
case "$FILE_PATH" in
  *.rs)
    STUB_COUNT=$(echo "$NEW_STRING" | vg_filter_suppressed "STUB" | grep -cE '^\s*(todo!\(|unimplemented!\(|panic!\("not implemented)' 2>/dev/null; true)
    if [[ "${STUB_COUNT:-0}" -gt 0 ]]; then
      STUB_WARNINGS="[STUB] 新增了 ${STUB_COUNT} 个 stub 占位符（todo!/unimplemented!）。必须在当前任务内替换为真实实现，或标记 DEFER 并说明原因。"
    fi
    ;;
  *.ts|*.tsx|*.js|*.jsx)
    STUB_COUNT=$(echo "$NEW_STRING" | vg_filter_suppressed "STUB" | grep -cE '^\s*(throw new Error\(.*(not implemented|TODO|FIXME)|// TODO|// FIXME|return null.*// stub)' 2>/dev/null; true)
    if [[ "${STUB_COUNT:-0}" -gt 0 ]]; then
      STUB_WARNINGS="[STUB] 新增了 ${STUB_COUNT} 个 stub 占位符（throw not implemented / TODO）。必须替换为真实实现或标记 DEFER。"
    fi
    ;;
  *.py)
    STUB_COUNT=$(echo "$NEW_STRING" | vg_filter_suppressed "STUB" | grep -cE '^\s*(pass\s*$|pass\s*#|raise NotImplementedError|# TODO|# FIXME)' 2>/dev/null; true)
    if [[ "${STUB_COUNT:-0}" -gt 0 ]]; then
      STUB_WARNINGS="[STUB] 新增了 ${STUB_COUNT} 个 stub 占位符（pass/NotImplementedError/TODO）。必须替换为真实实现或标记 DEFER。"
    fi
    ;;
  *.go)
    STUB_COUNT=$(echo "$NEW_STRING" | vg_filter_suppressed "STUB" | grep -cE '^\s*(panic\("not implemented|// TODO|// FIXME)' 2>/dev/null; true)
    if [[ "${STUB_COUNT:-0}" -gt 0 ]]; then
      STUB_WARNINGS="[STUB] 新增了 ${STUB_COUNT} 个 stub 占位符（panic not implemented / TODO）。必须替换为真实实现或标记 DEFER。"
    fi
    ;;
esac
if [[ -n "$STUB_WARNINGS" ]]; then
  WARNINGS="${WARNINGS:+${WARNINGS} }${STUB_WARNINGS}"
fi

# --- 超大 diff 检测（可能是幻觉编辑） ---
DIFF_LINES=$(echo "$NEW_STRING" | wc -l | tr -d ' ')
if [[ $DIFF_LINES -gt 200 ]]; then
  WARNINGS="${WARNINGS:+${WARNINGS} }[LARGE-EDIT] 单次编辑 ${DIFF_LINES} 行，超出 200 行阈值，请确认编辑内容正确。"
fi

# --- Churn Detection（同文件反复编辑 → 可能在循环修正） ---
# 分级升级：5=提醒, 10=警告, 20+=强制停下
CHURN_COUNT=$(VG_LOG_FILE="$VIBEGUARD_LOG_FILE" VG_FILE_PATH="$FILE_PATH" VG_SESSION="$VIBEGUARD_SESSION_ID" python3 -c '
import json, os
log_file = os.environ.get("VG_LOG_FILE", "")
file_path = os.environ.get("VG_FILE_PATH", "")
session = os.environ.get("VG_SESSION", "")
count = 0
try:
    with open(log_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
                if e.get("session") == session and e.get("tool") == "Edit" and file_path in e.get("detail", ""):
                    count += 1
            except (json.JSONDecodeError, KeyError):
                continue
except FileNotFoundError:
    pass
print(count)
' 2>/dev/null | tr -d '[:space:]' || echo "0")
CHURN_COUNT="${CHURN_COUNT:-0}"

if [[ "$CHURN_COUNT" -ge 20 ]]; then
  WARNINGS="${WARNINGS:+${WARNINGS} }[CHURN CRITICAL] ${FILE_PATH##*/} 已编辑 ${CHURN_COUNT} 次！你正处于 edit→fail→fix 死循环。必须立即停止当前方向，重新审视根因（W-02）。"
  vg_log "post-edit-guard" "Edit" "escalate" "churn ${CHURN_COUNT}x critical" "$FILE_PATH"
elif [[ "$CHURN_COUNT" -ge 10 ]]; then
  WARNINGS="${WARNINGS:+${WARNINGS} }[CHURN WARNING] ${FILE_PATH##*/} 已编辑 ${CHURN_COUNT} 次，疑似循环修正。建议：停下来运行完整构建查看全貌，或 /vibeguard:learn 提取模式。"
  vg_log "post-edit-guard" "Edit" "escalate" "churn ${CHURN_COUNT}x warning" "$FILE_PATH"
elif [[ "$CHURN_COUNT" -ge 5 ]]; then
  WARNINGS="${WARNINGS:+${WARNINGS} }[CHURN] ${FILE_PATH##*/} 已编辑 ${CHURN_COUNT} 次，注意是否在循环修正。"
  vg_log "post-edit-guard" "Edit" "correction" "churn ${CHURN_COUNT}x" "$FILE_PATH"
fi

if [[ -z "$WARNINGS" ]]; then
  vg_log "post-edit-guard" "Edit" "pass" "" "$FILE_PATH"
  exit 0
fi

# --- Escalation 检测 ---
# 同一文件在当前日志中被 warn 3 次以上 → 升级为 escalate
DECISION="warn"
WARN_COUNT_FOR_FILE=$(VG_LOG_FILE="$VIBEGUARD_LOG_FILE" VG_FILE_PATH="$FILE_PATH" VG_SESSION="$VIBEGUARD_SESSION_ID" python3 -c '
import json, os
log_file = os.environ.get("VG_LOG_FILE", "")
file_path = os.environ.get("VG_FILE_PATH", "")
session = os.environ.get("VG_SESSION", "")
count = 0
try:
    with open(log_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
                # 限定当前 session + 精确路径匹配（避免子路径误判）
                if e.get("session") == session and e.get("hook") == "post-edit-guard" and e.get("decision") == "warn" and e.get("detail", "").split("||")[0].strip() == file_path:
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

#!/usr/bin/env bash
# VibeGuard PostToolUse(Edit|Write) Hook — 编辑后自动构建检查
#
# 编辑源码文件后自动运行对应语言的构建检查：
#   - Rust (.rs): cargo check
#   - TypeScript (.ts/.tsx): npx tsc --noEmit
#   - JavaScript (.js/.mjs/.cjs): node --check
#   - Go (.go): go build ./...
#
# 只输出警告，不阻止操作。

set -euo pipefail

source "$(dirname "$0")/log.sh"

INPUT=$(cat)

# 从 Edit 或 Write 的 JSON 中提取 file_path
FILE_PATH=$(echo "$INPUT" | vg_json_field "tool_input.file_path")

if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

# 获取文件扩展名
BASENAME=$(basename "$FILE_PATH")
EXT="${BASENAME##*.}"

# 只处理需要构建检查的语言
case "$EXT" in
  rs|ts|tsx|go|js|mjs|cjs) ;;
  *) exit 0 ;;
esac

# 向上查找项目根目录（根据语言查找不同的标记文件）
find_project_root() {
  local dir="$1"
  local marker="$2"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/$marker" ]]; then
      echo "$dir"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  return 1
}

ERRORS=""

case "$EXT" in
  rs)
    PROJECT_ROOT=$(find_project_root "$(dirname "$FILE_PATH")" "Cargo.toml") || exit 0
    # cargo check，限制输出
    ERRORS=$(cd "$PROJECT_ROOT" && cargo check --message-format=short 2>&1 | grep -E "^error" | head -10) || true
    ;;
  ts|tsx)
    PROJECT_ROOT=$(find_project_root "$(dirname "$FILE_PATH")" "tsconfig.json") || exit 0
    # tsc 类型检查
    ERRORS=$(cd "$PROJECT_ROOT" && npx tsc --noEmit 2>&1 | grep -E "error TS" | head -10) || true
    ;;
  js|mjs|cjs)
    # JavaScript 语法检查（不依赖 tsconfig）
    command -v node >/dev/null 2>&1 || exit 0
    ERRORS=$(node --check "$FILE_PATH" 2>&1 | head -10) || true
    ;;
  go)
    PROJECT_ROOT=$(find_project_root "$(dirname "$FILE_PATH")" "go.mod") || exit 0
    # go build 检查
    ERRORS=$(cd "$PROJECT_ROOT" && go build ./... 2>&1 | head -10) || true
    ;;
esac

if [[ -z "$ERRORS" ]]; then
  vg_log "post-build-check" "Edit" "pass" "" "$FILE_PATH"
  exit 0
fi

ERROR_COUNT=$(echo "$ERRORS" | wc -l | tr -d ' ')
WARNINGS="[BUILD] 编辑 ${BASENAME} 后检测到 ${ERROR_COUNT} 个构建错误：
${ERRORS}"

# --- Escalation 检测：连续构建失败升级 ---
DECISION="warn"
CONSECUTIVE_FAILS=$(VG_LOG_FILE="$VIBEGUARD_LOG_FILE" python3 -c '
import json, os
log_file = os.environ.get("VG_LOG_FILE", "")
count = 0
try:
    with open(log_file) as f:
        lines = f.readlines()
    # 从末尾倒序读，遇到 pass 就停止计数
    for line in reversed(lines):
        line = line.strip()
        if not line: continue
        try:
            e = json.loads(line)
            if e.get("hook") != "post-build-check": continue
            if e.get("decision") == "pass":
                break
            if e.get("decision") == "warn":
                count += 1
        except: continue
except: pass
print(count)
' 2>/dev/null | tr -d '[:space:]' || echo "0")
CONSECUTIVE_FAILS="${CONSECUTIVE_FAILS:-0}"

if [[ "$CONSECUTIVE_FAILS" -ge 5 ]]; then
  DECISION="escalate"
  WARNINGS="[U-25 ESCALATE] 连续 ${CONSECUTIVE_FAILS} 次构建失败！必须先修复构建错误再继续编辑。建议：运行完整构建命令查看全部错误，定位根因一次性修复。${WARNINGS}"
fi

vg_log "post-build-check" "Edit" "$DECISION" "构建错误 ${ERROR_COUNT} 个" "$FILE_PATH"

VG_WARNINGS="$WARNINGS" VG_DECISION="$DECISION" python3 -c '
import json, os
warnings = os.environ.get("VG_WARNINGS", "")
decision = os.environ.get("VG_DECISION", "warn")
prefix = "VIBEGUARD 构建升级警告" if decision == "escalate" else "VIBEGUARD 构建检查"
result = {
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": prefix + "：" + warnings
    }
}
print(json.dumps(result, ensure_ascii=False))
'

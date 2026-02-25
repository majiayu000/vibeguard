#!/usr/bin/env bash
# VibeGuard PostToolUse(Edit|Write) Hook — 编辑后自动构建检查
#
# 编辑源码文件后自动运行对应语言的构建检查：
#   - Rust (.rs): cargo check
#   - TypeScript (.ts/.tsx): npx tsc --noEmit
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
  rs|ts|tsx|go) ;;
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

vg_log "post-build-check" "Edit" "warn" "构建错误 ${ERROR_COUNT} 个" "$FILE_PATH"

VG_WARNINGS="$WARNINGS" python3 -c '
import json, os
warnings = os.environ.get("VG_WARNINGS", "")
result = {
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": "VIBEGUARD 构建检查：" + warnings
    }
}
print(json.dumps(result, ensure_ascii=False))
'

#!/usr/bin/env bash
# VibeGuard TypeScript Guard — [TS-13] 禁止 API 路由直接调用模型 SDK
#
# 目的：阻止在 API 路由层直接 import/调用模型 SDK，避免绕过统一任务层。
# 典型风险：
# 1) API handler 直接依赖 openai / ai-sdk / llm-client
# 2) API handler 中直接调用 chatCompletion/generateText/streamText
#
# 用法：
#   bash check_no_api_direct_ai_call.sh [--strict] [target_dir]
#
# --strict 模式：任何违规都以非零退出码退出

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
parse_guard_args "$@"

ALLOW_PREFIXES="${VG_API_GUARD_ALLOW_PREFIXES:-}"
RESULTS=$(create_tmpfile)
COUNT=0

is_api_file() {
  local rel="$1"
  case "$rel" in
    src/app/api/*|src/pages/api/*|src/api/*|*/api/*|*/route.ts|*/route.tsx|*/route.js|*/route.jsx)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_allowed_file() {
  local rel="$1"
  [[ -z "$ALLOW_PREFIXES" ]] && return 1
  local old_ifs="$IFS"
  IFS=','
  for prefix in $ALLOW_PREFIXES; do
    prefix="$(echo "$prefix" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -z "$prefix" ]] && continue
    case "$rel" in
      "$prefix"*) IFS="$old_ifs"; return 0 ;;
    esac
  done
  IFS="$old_ifs"
  return 1
}

record_matches() {
  local code="$1"
  local rel="$2"
  local pattern="$3"
  local advice="$4"
  local file="$5"
  while IFS= read -r line_info; do
    [[ -z "$line_info" ]] && continue
    local line_num
    line_num=$(echo "$line_info" | cut -d: -f1)
    local line_text
    line_text=$(echo "$line_info" | cut -d: -f2-)
    local trimmed
    trimmed=$(echo "$line_text" | sed 's/^[[:space:]]*//')
    case "$trimmed" in
      //*|'*'*) continue ;;
    esac
    echo "[${code}] ${rel}:${line_num} ${advice}" >> "$RESULTS"
    COUNT=$((COUNT + 1))
  done < <(grep -nE "$pattern" "$file" 2>/dev/null || true)
}

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  [[ ! -f "$file" ]] && continue
  rel="${file#${TARGET_DIR}/}"
  is_api_file "$rel" || continue
  if is_allowed_file "$rel"; then
    continue
  fi

  # 直接 import 模型客户端
  record_matches \
    "TS-13" \
    "$rel" \
    "from[[:space:]]+['\"](@/lib/llm-client|@/lib/llm|openai|@ai-sdk/[^'\"]+)['\"]" \
    "forbidden direct model SDK import in API layer; route should delegate to unified task/runtime layer" \
    "$file"

  # 直接调用模型接口
  record_matches \
    "TS-13" \
    "$rel" \
    "\\b(chatCompletion[A-Za-z0-9_]*|generateText|streamText|responses\\.create)\\s*\\(" \
    "forbidden direct model invocation in API layer; submit task and execute in worker/runtime" \
    "$file"
done < <(list_ts_files "$TARGET_DIR" | filter_non_test)

if [[ $COUNT -eq 0 ]]; then
  echo "[TS-13] PASS: no direct model invocation found in API layer"
  exit 0
fi

echo "[TS-13] detected ${COUNT} API direct model call/import issues:"
echo
cat "$RESULTS"

if [[ "$STRICT" == "true" ]]; then
  exit 1
fi


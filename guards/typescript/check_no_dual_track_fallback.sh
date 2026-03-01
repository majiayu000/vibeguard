#!/usr/bin/env bash
# VibeGuard TypeScript Guard — [TS-14] 禁止双轨执行与隐式回退
#
# 目的：阻止同一路径中出现“新链路 + 旧链路”双轨并存，或通过同步/回退分支掩盖问题。
# 默认检测 API 路由中的高风险标记：
# - isInternalTaskExecution
# - shouldRunSyncTask(...)
# - maybeSubmitLLMTask(...) 但无显式注释说明已禁用 sync/fallback
#
# 用法：
#   bash check_no_dual_track_fallback.sh [--strict] [target_dir]
#
# 可选环境变量：
#   VG_FALLBACK_ALLOW_PREFIXES="src/app/api/internal/,src/pages/api/debug/"
#
# --strict 模式：任何违规都以非零退出码退出

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
parse_guard_args "$@"

ALLOW_PREFIXES="${VG_FALLBACK_ALLOW_PREFIXES:-}"
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
  local rel="$1"
  local pattern="$2"
  local advice="$3"
  local file="$4"
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
    echo "[TS-14] ${rel}:${line_num} ${advice}" >> "$RESULTS"
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

  record_matches \
    "$rel" \
    "\\bisInternalTaskExecution\\b" \
    "forbidden dual-track marker isInternalTaskExecution; keep a single execution path" \
    "$file"

  record_matches \
    "$rel" \
    "\\bshouldRunSyncTask\\s*\\(" \
    "forbidden sync fallback branch shouldRunSyncTask(); use explicit async task path only" \
    "$file"

  if grep -q "\\bmaybeSubmitLLMTask\\s*\\(" "$file" 2>/dev/null; then
    if ! grep -q "sync mode is disabled" "$file" 2>/dev/null; then
      echo "[TS-14] ${rel} maybeSubmitLLMTask() used without explicit 'sync mode is disabled' assertion/comment" >> "$RESULTS"
      COUNT=$((COUNT + 1))
    fi
  fi
done < <(list_ts_files "$TARGET_DIR" | filter_non_test)

if [[ $COUNT -eq 0 ]]; then
  echo "[TS-14] PASS: no dual-track fallback markers found"
  exit 0
fi

echo "[TS-14] detected ${COUNT} dual-track fallback issues:"
echo
cat "$RESULTS"

if [[ "$STRICT" == "true" ]]; then
  exit 1
fi


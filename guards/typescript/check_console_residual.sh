#!/usr/bin/env bash
# VibeGuard TypeScript Guard — [TS-03] console 残留检测
#
# 检测非测试文件中的 console.log、console.warn、console.error 残留。
# 与 post-edit-guard 的实时检测互补，这个脚本做项目级全量扫描。
#
# 用法：
#   bash check_console_residual.sh [--strict] [target_dir]
#
# --strict 模式：任何违规都以非零退出码退出

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
parse_guard_args "$@"

RESULTS=$(create_tmpfile)
COUNT=0

# CLI 项目（package.json 含 bin 字段）允许使用 console，跳过整个检查
if [[ -f "${TARGET_DIR}/package.json" ]] && grep -q '"bin"' "${TARGET_DIR}/package.json" 2>/dev/null; then
  echo "[TS-03] SKIP: CLI 项目（package.json 含 bin），console 为正常输出方式"
  exit 0
fi

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  [[ ! -f "$file" ]] && continue

  REL_PATH="${file#${TARGET_DIR}/}"

  # 排除合理使用 console 的文件
  case "$REL_PATH" in
    *logger*|*logging*|*log.config*) continue ;;
    */debug.*|*/debug/*) continue ;;
  esac

  # MCP 入口文件用 console.error 输出到 stderr 是协议标准做法，跳过
  if grep -qE '(StdioServerTransport|new Server\(|McpServer)' "$file" 2>/dev/null; then
    continue
  fi

  while IFS= read -r line_info; do
    [[ -z "$line_info" ]] && continue
    LINE_NUM=$(echo "$line_info" | cut -d: -f1)
    LINE_CONTENT=$(echo "$line_info" | cut -d: -f2-)
    # 跳过注释行
    TRIMMED=$(echo "$LINE_CONTENT" | sed 's/^[[:space:]]*//')
    case "$TRIMMED" in
      //*|'*'*) continue ;;
    esac
    echo "[TS-03] ${REL_PATH}:${LINE_NUM} console 残留。修复：使用项目 logger 替代，或删除调试代码" >> "$RESULTS"
    COUNT=$((COUNT + 1))
  done < <(grep -nE '\bconsole\.(log|warn|error|debug|info)\(' "$file" 2>/dev/null || true)

done < <(list_ts_files "$TARGET_DIR" | filter_non_test)

if [[ $COUNT -eq 0 ]]; then
  echo "[TS-03] PASS: 未检测到 console 残留"
  exit 0
fi

echo "[TS-03] 检测到 ${COUNT} 处 console 残留:"
echo
cat "$RESULTS"

if [[ "$STRICT" == "true" ]]; then
  exit 1
fi

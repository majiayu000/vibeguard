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

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  [[ ! -f "$file" ]] && continue

  REL_PATH="${file#${TARGET_DIR}/}"

  # 排除 logger 配置文件
  case "$REL_PATH" in
    *logger*|*logging*|*log.config*) continue ;;
  esac

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

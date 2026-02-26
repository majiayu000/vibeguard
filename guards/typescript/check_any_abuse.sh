#!/usr/bin/env bash
# VibeGuard TypeScript Guard — [TS-01] any 类型滥用检测
#
# 检测非测试文件中的 `as any`、`@ts-ignore`、`@ts-nocheck`、`: any` 使用。
# 这些写法绕过了 TypeScript 类型系统的保护，应尽量避免。
#
# 用法：
#   bash check_any_abuse.sh [--strict] [target_dir]
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

  # 检测 as any
  while IFS= read -r line_info; do
    [[ -z "$line_info" ]] && continue
    LINE_NUM=$(echo "$line_info" | cut -d: -f1)
    LINE_CONTENT=$(echo "$line_info" | cut -d: -f2-)
    echo "[TS-01] ${REL_PATH}:${LINE_NUM} 'as any' 绕过类型检查。修复：使用具体类型或类型断言 'as SpecificType'" >> "$RESULTS"
    COUNT=$((COUNT + 1))
  done < <(grep -n '\bas any\b' "$file" 2>/dev/null || true)

  # 检测 : any（函数参数、变量声明）
  while IFS= read -r line_info; do
    [[ -z "$line_info" ]] && continue
    LINE_NUM=$(echo "$line_info" | cut -d: -f1)
    echo "[TS-01] ${REL_PATH}:${LINE_NUM} ': any' 类型注解。修复：使用具体类型替代 any" >> "$RESULTS"
    COUNT=$((COUNT + 1))
  done < <(grep -nE ':\s*any\b' "$file" 2>/dev/null | grep -vE '//.*:\s*any' || true)

  # 检测 @ts-ignore
  while IFS= read -r line_info; do
    [[ -z "$line_info" ]] && continue
    LINE_NUM=$(echo "$line_info" | cut -d: -f1)
    echo "[TS-02] ${REL_PATH}:${LINE_NUM} '@ts-ignore' 禁用类型检查。修复：修复类型错误而非忽略" >> "$RESULTS"
    COUNT=$((COUNT + 1))
  done < <(grep -n '@ts-ignore' "$file" 2>/dev/null || true)

  # 检测 @ts-nocheck
  while IFS= read -r line_info; do
    [[ -z "$line_info" ]] && continue
    LINE_NUM=$(echo "$line_info" | cut -d: -f1)
    echo "[TS-02] ${REL_PATH}:${LINE_NUM} '@ts-nocheck' 禁用整个文件类型检查。修复：逐个修复类型错误" >> "$RESULTS"
    COUNT=$((COUNT + 1))
  done < <(grep -n '@ts-nocheck' "$file" 2>/dev/null || true)

done < <(list_ts_files "$TARGET_DIR" | filter_non_test)

if [[ $COUNT -eq 0 ]]; then
  echo "[TS-01] PASS: 未检测到 any 类型滥用"
  exit 0
fi

echo "[TS-01] 检测到 ${COUNT} 处 any 类型滥用:"
echo
cat "$RESULTS"

if [[ "$STRICT" == "true" ]]; then
  exit 1
fi

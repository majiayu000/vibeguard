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
    printf '[TS-01] [review] [this-line] OBSERVATION: %s:%s uses "as any" bypassing type safety\nFIX: Replace "as any" with a specific type or "as SpecificType"\nDO NOT: Refactor other files, create type utility modules, or fix any usage outside this line\n\n' "${REL_PATH}" "${LINE_NUM}" >> "$RESULTS"
    COUNT=$((COUNT + 1))
  done < <(grep -n '\bas any\b' "$file" 2>/dev/null || true)

  # 检测 : any（函数参数、变量声明）
  # 排除：行注释、块注释开头、字符串赋值（= "..." 内的 : any）
  while IFS= read -r line_info; do
    [[ -z "$line_info" ]] && continue
    LINE_NUM=$(echo "$line_info" | cut -d: -f1)
    printf '[TS-01] [review] [this-line] OBSERVATION: %s:%s uses ": any" type annotation\nFIX: Replace ": any" with a specific type\nDO NOT: Refactor other files or create type utility modules\n\n' "${REL_PATH}" "${LINE_NUM}" >> "$RESULTS"
    COUNT=$((COUNT + 1))
  done < <(grep -nE ':\s*any\b' "$file" 2>/dev/null \
    | grep -vE '//.*:\s*any' \
    | grep -vE '^\s*[0-9]+:\s*/?\*' \
    | grep -vE '=\s*["\x27`].*:\s*any' \
    || true)

  # 检测 @ts-ignore
  while IFS= read -r line_info; do
    [[ -z "$line_info" ]] && continue
    LINE_NUM=$(echo "$line_info" | cut -d: -f1)
    printf '[TS-02] [review] [this-line] OBSERVATION: %s:%s uses @ts-ignore suppressing a type error\nFIX: Fix the underlying type error on the suppressed line\nDO NOT: Suppress additional lines, create ignore lists, or modify other files\n\n' "${REL_PATH}" "${LINE_NUM}" >> "$RESULTS"
    COUNT=$((COUNT + 1))
  done < <(grep -n '@ts-ignore' "$file" 2>/dev/null || true)

  # 检测 @ts-nocheck
  while IFS= read -r line_info; do
    [[ -z "$line_info" ]] && continue
    LINE_NUM=$(echo "$line_info" | cut -d: -f1)
    printf '[TS-02] [review] [this-file] OBSERVATION: %s:%s uses @ts-nocheck disabling type checking for the whole file\nFIX: Remove @ts-nocheck and fix the type errors it was hiding, one at a time\nDO NOT: Move @ts-nocheck to other files or create a tsconfig exclude entry\n\n' "${REL_PATH}" "${LINE_NUM}" >> "$RESULTS"
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

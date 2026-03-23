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

# Pre-commit diff-only mode: only check lines added in staged diff
if [[ -n "${VIBEGUARD_STAGED_FILES:-}" ]] && [[ -f "${VIBEGUARD_STAGED_FILES}" ]]; then
  STAGED_TS=$(grep -E '\.(ts|tsx|js|jsx)$' "${VIBEGUARD_STAGED_FILES}" \
    | grep -vE '(\.(test|spec)\.(ts|tsx|js|jsx)$|/__tests__/|/test/)' || true)
  if [[ -n "${STAGED_TS}" ]]; then
    while IFS= read -r f; do
      [[ -z "$f" || ! -f "$f" ]] && continue
      REL_PATH="${f#${TARGET_DIR}/}"
      DIFF_LINES=$(git diff --cached -U0 -- "${f}" 2>/dev/null | grep '^+' | grep -v '^+++' || true)
      [[ -z "${DIFF_LINES}" ]] && continue

      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        echo "[TS-01] ${REL_PATH}: 'as any' 绕过类型检查。修复：使用具体类型或类型断言 'as SpecificType'" >> "${RESULTS}"
        COUNT=$((COUNT + 1))
      done < <(echo "${DIFF_LINES}" | grep -E '\bas any\b' || true)

      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        echo "[TS-01] ${REL_PATH}: ': any' 类型注解。修复：使用具体类型替代 any" >> "${RESULTS}"
        COUNT=$((COUNT + 1))
      done < <(echo "${DIFF_LINES}" \
        | grep -E ':\s*any\b' \
        | grep -vE '//.*:\s*any' \
        | grep -vE '^\+\s*/?[*]' \
        | grep -vE '=\s*["'\''`].*:\s*any' \
        || true)

      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        echo "[TS-02] ${REL_PATH}: '@ts-ignore' 禁用类型检查。修复：修复类型错误而非忽略" >> "${RESULTS}"
        COUNT=$((COUNT + 1))
      done < <(echo "${DIFF_LINES}" | grep '@ts-ignore' || true)

      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        echo "[TS-02] ${REL_PATH}: '@ts-nocheck' 禁用整个文件类型检查。修复：逐个修复类型错误" >> "${RESULTS}"
        COUNT=$((COUNT + 1))
      done < <(echo "${DIFF_LINES}" | grep '@ts-nocheck' || true)

    done <<< "${STAGED_TS}"
  fi
else
  # Full-file scan mode (post-edit or explicit check)
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
    # 排除：行注释、块注释开头、字符串赋值（= "..." 内的 : any）
    while IFS= read -r line_info; do
      [[ -z "$line_info" ]] && continue
      LINE_NUM=$(echo "$line_info" | cut -d: -f1)
      echo "[TS-01] ${REL_PATH}:${LINE_NUM} ': any' 类型注解。修复：使用具体类型替代 any" >> "$RESULTS"
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
fi

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

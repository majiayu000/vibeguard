#!/usr/bin/env bash
# VibeGuard TypeScript Guard — [TS-15] 重复定义检测（常量/类型/函数）
#
# 检测 TypeScript/JavaScript 项目中跨文件重复定义问题。
# 相比旧版脚本，本脚本修复了两个关键问题：
# 1) 计数不再受子 shell 作用域影响，Summary 与明细一致
# 2) 自动忽略 Next.js Route Handler 的 GET/POST 等合法重复导出
#
# 用法：
#   bash check_duplicate_constants.sh [--strict] [target_dir]
#
# --strict 模式：任何违规都以非零退出码退出

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
parse_guard_args "$@"

SRC_DIR="${TARGET_DIR}/src"
if [[ ! -d "${SRC_DIR}" ]]; then
  echo "[TS-15] PASS: no src/ directory found"
  exit 0
fi

CONST_RECORDS=$(create_tmpfile)
TYPE_RECORDS=$(create_tmpfile)
FUNC_RECORDS=$(create_tmpfile)
ISSUES=0

is_http_method_name() {
  case "$1" in
    GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS) return 0 ;;
    *) return 1 ;;
  esac
}

should_skip_route_method_const() {
  local name="$1"
  local rel_path="$2"
  if ! is_http_method_name "$name"; then
    return 1
  fi
  case "$rel_path" in
    */api/*|*/route.ts|*/route.tsx|*/route.js|*/route.jsx) return 0 ;;
    *) return 1 ;;
  esac
}

echo "=== VibeGuard: Duplicate Definition Check ==="
echo

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  [[ ! -f "$file" ]] && continue

  case "$file" in
    "${SRC_DIR}/"*) ;;
    *) continue ;;
  esac

  rel_path="${file#${TARGET_DIR}/}"

  while IFS= read -r line_info; do
    [[ -z "$line_info" ]] && continue
    name=$(echo "$line_info" | sed -E 's/.*export const ([A-Z][A-Z0-9_]*).*/\1/')
    [[ -z "$name" ]] && continue
    if should_skip_route_method_const "$name" "$rel_path"; then
      continue
    fi
    printf "%s\t%s\n" "$name" "$rel_path" >> "$CONST_RECORDS"
  done < <(grep -nE 'export const [A-Z][A-Z0-9_]*\b' "$file" 2>/dev/null || true)

  while IFS= read -r line_info; do
    [[ -z "$line_info" ]] && continue
    name=$(echo "$line_info" | sed -E 's/.*export (type|interface) ([A-Z][A-Za-z0-9_]*).*/\2/')
    [[ -z "$name" ]] && continue
    printf "%s\t%s\n" "$name" "$rel_path" >> "$TYPE_RECORDS"
  done < <(grep -nE 'export (type|interface) [A-Z][A-Za-z0-9_]*\b' "$file" 2>/dev/null || true)

  while IFS= read -r line_info; do
    [[ -z "$line_info" ]] && continue
    name=$(echo "$line_info" | sed -E 's/.*function ([a-z][A-Za-z0-9_]*).*/\1/')
    [[ -z "$name" ]] && continue
    printf "%s\t%s\n" "$name" "$rel_path" >> "$FUNC_RECORDS"
  done < <(grep -nE '\bfunction [a-z][A-Za-z0-9_]*\b' "$file" 2>/dev/null || true)
done < <(list_ts_files "$TARGET_DIR" | filter_non_test)

sort -u "$CONST_RECORDS" -o "$CONST_RECORDS"
sort -u "$TYPE_RECORDS" -o "$TYPE_RECORDS"
sort -u "$FUNC_RECORDS" -o "$FUNC_RECORDS"

report_duplicates() {
  local records_file="$1"
  local label="$2"
  local threshold="$3"
  local remediation="$4"
  local summary_hint="$5"

  [[ -s "$records_file" ]] || return 0

  local names_file
  names_file=$(create_tmpfile)
  cut -f1 "$records_file" | sort | uniq -c > "$names_file"

  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    local count
    local name
    count=$(echo "$row" | awk '{print $1}')
    name=$(echo "$row" | awk '{print $2}')
    [[ -z "$name" ]] && continue

    if [[ "$count" -lt "$threshold" ]]; then
      continue
    fi

    local files
    files=$(awk -F'\t' -v n="$name" '$1==n {print $2}' "$records_file" | sort -u)
    local file_count
    file_count=$(echo "$files" | grep -c . || true)
    if [[ "$file_count" -lt "$threshold" ]]; then
      continue
    fi

    echo "[${label}] ${name} defined in ${file_count} files${summary_hint}:"
    echo "$files" | sed 's/^/  - /'
    echo "  Remediation: ${remediation}"
    echo
    ISSUES=$((ISSUES + 1))
  done < "$names_file"
}

echo "--- Checking duplicate const definitions ---"
report_duplicates \
  "$CONST_RECORDS" \
  "DUP-CONST" \
  2 \
  "keep one source of truth and import it everywhere else" \
  ""

echo "--- Checking duplicate type/interface definitions ---"
report_duplicates \
  "$TYPE_RECORDS" \
  "DUP-TYPE" \
  2 \
  "centralize shared types and re-export from a single module" \
  ""

echo "--- Checking duplicate function definitions ---"
report_duplicates \
  "$FUNC_RECORDS" \
  "DUP-FUNC" \
  3 \
  "extract shared helper into a reusable module" \
  " (>=3 = must abstract)"

echo "=== Summary: ${ISSUES} duplicate issues found ==="

if [[ "$STRICT" == "true" ]] && [[ "$ISSUES" -gt 0 ]]; then
  exit 1
fi

exit 0

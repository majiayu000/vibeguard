#!/usr/bin/env bash
# VibeGuard Guard: check_component_duplication.sh (TS-13)
# 检测 React 组件和 Hook 的功能级重复（异名同功能）
#
# 用法:
#   bash check_component_duplication.sh [project_dir]
#   bash check_component_duplication.sh --strict [project_dir]
#
# 检测规则:
#   1. UI 原语重复：多个文件定义了 <label> + children + required 的 FormField 模式
#   2. 表格排序重复：多个文件各自实现 useState(sort) + <table> 模式
#   3. 查询 Hook 模板重复：多个 use*Hook 重复 useQuery → 标准化返回结构
#   4. 样式常量重复：多个文件定义相同的 className/style 字符串

source "$(dirname "$0")/common.sh"
parse_guard_args "$@"

SRC_DIR="${TARGET_DIR}/src"
if [[ ! -d "$SRC_DIR" ]]; then
  echo "[PASS] No src/ directory found"
  exit 0
fi

ISSUES=0

echo "=== VibeGuard: Component/Hook Duplication Check (TS-13) ==="
echo ""

# --- 检查 1: FormField 模式重复 ---
# 检测同时包含 <label 和 {children} 的组件定义文件（UI 原语特征）
echo "--- Checking FormField-like pattern duplication ---"

FORMFIELD_FILES=$(mktemp)
list_ts_files "${TARGET_DIR}" | filter_non_test | while IFS= read -r f; do
  if [[ -f "$f" ]]; then
    has_label=$(grep -cE '<label' "$f" 2>/dev/null || true)
    has_children=$(grep -cE '\{children\}|\{props\.children\}' "$f" 2>/dev/null || true)
    # 只匹配 prop 级 required（排除 HTML 原生 <input required>）
    has_required=$(grep -cE 'isRequired|required\s*[?:}]|props\.required' "$f" 2>/dev/null || true)
    if [[ "$has_label" -gt 0 && "$has_children" -gt 0 && "$has_required" -gt 0 ]]; then
      echo "$f" >> "$FORMFIELD_FILES"
    fi
  fi
done

FORMFIELD_COUNT=$(wc -l < "$FORMFIELD_FILES" | tr -d ' ')
if [[ "$FORMFIELD_COUNT" -ge 3 ]]; then
  echo "[TS-13] FormField-like pattern found in ${FORMFIELD_COUNT} files (>=3 = must extract):"
  sed 's/^/  - /' "$FORMFIELD_FILES"
  echo "  Remediation: 提取到 components/ui/FormField.tsx，其他文件改为 import"
  echo ""
  ISSUES=$((ISSUES + 1))
elif [[ "$FORMFIELD_COUNT" -ge 2 ]]; then
  echo "[INFO] FormField-like pattern found in ${FORMFIELD_COUNT} files (monitor for 3rd occurrence)"
  sed 's/^/  - /' "$FORMFIELD_FILES"
  echo ""
fi
rm -f "$FORMFIELD_FILES"

# --- 检查 2: 表格排序模式重复 ---
# 检测同时包含 useState+sort 和 <table/<th 的组件（排序表格特征）
echo "--- Checking table sort pattern duplication ---"

SORT_TABLE_FILES=$(mktemp)
list_ts_files "${TARGET_DIR}" | filter_non_test | while IFS= read -r f; do
  if [[ -f "$f" ]]; then
    # 收紧：要求 useState + sort 相关状态，排除 API 参数中的 sortKey
    has_sort_state=$(grep -cE 'useState.*sort|setSortKey|setSortDir|setSortOrder' "$f" 2>/dev/null || true)
    has_table=$(grep -cE '<table|<Table|<th|<thead' "$f" 2>/dev/null || true)
    if [[ "$has_sort_state" -gt 0 && "$has_table" -gt 0 ]]; then
      echo "$f" >> "$SORT_TABLE_FILES"
    fi
  fi
done

SORT_COUNT=$(wc -l < "$SORT_TABLE_FILES" | tr -d ' ')
if [[ "$SORT_COUNT" -ge 2 ]]; then
  echo "[TS-13] Sortable table pattern found in ${SORT_COUNT} files (>=2 = should extract):"
  sed 's/^/  - /' "$SORT_TABLE_FILES"
  echo "  Remediation: 提取到 components/ui/DataTable.tsx，抽象排序逻辑到 hooks/useTableSort.ts"
  echo ""
  ISSUES=$((ISSUES + 1))
fi
rm -f "$SORT_TABLE_FILES"

# --- 检查 3: 查询 Hook 模板重复 ---
# 检测多个自定义 Hook 文件包含相同的 useQuery + 标准化返回模式
echo "--- Checking query hook template duplication ---"

QUERY_HOOK_FILES=$(mktemp)
list_ts_files "${TARGET_DIR}" | filter_non_test | grep -iE '(use[A-Z].*\.(ts|tsx)$|hooks/)' | while IFS= read -r f; do
  if [[ -f "$f" ]]; then
    has_query=$(grep -cE 'useQuery|useSWR|useInfiniteQuery' "$f" 2>/dev/null || true)
    has_standard_return=$(grep -cE 'isLoading|loading.*error|refetch|data.*error' "$f" 2>/dev/null || true)
    if [[ "$has_query" -gt 0 && "$has_standard_return" -gt 0 ]]; then
      echo "$f" >> "$QUERY_HOOK_FILES"
    fi
  fi
done

QUERY_COUNT=$(wc -l < "$QUERY_HOOK_FILES" | tr -d ' ')
# 提高阈值：3 → 4，减少标准 useQuery 模式的误报
if [[ "$QUERY_COUNT" -ge 4 ]]; then
  echo "[TS-13] Query hook template pattern found in ${QUERY_COUNT} files (>=3 = must abstract):"
  sed 's/^/  - /' "$QUERY_HOOK_FILES"
  echo "  Remediation: 提取公共 useQueryTemplate<T> hook，参数化 queryKey/queryFn/返回类型"
  echo ""
  ISSUES=$((ISSUES + 1))
elif [[ "$QUERY_COUNT" -ge 2 ]]; then
  echo "[INFO] Query hook template found in ${QUERY_COUNT} files (monitor for 3rd occurrence)"
  sed 's/^/  - /' "$QUERY_HOOK_FILES"
  echo ""
fi
rm -f "$QUERY_HOOK_FILES"

# --- 检查 4: 样式常量重复 ---
# 检测相同的长 className 字符串出现在多个文件中
echo "--- Checking duplicate style constants ---"

STYLE_DUPS=$(mktemp)
list_ts_files "${TARGET_DIR}" | filter_non_test | while IFS= read -r f; do
  if [[ -f "$f" ]]; then
    # 提取长度 >= 60 的 className/class 字符串值
    grep -oE "(className|class|Style)\s*[:=]\s*['\"][^'\"]{60,}['\"]" "$f" 2>/dev/null \
      | sed "s/^/${f}:/" || true
  fi
done | sort -t: -k2 > "$STYLE_DUPS"

# 提取重复的样式值
STYLE_VALUES=$(mktemp)
cut -d: -f2- "$STYLE_DUPS" | sort | uniq -c | sort -rn | while read -r count value; do
  if [[ "$count" -ge 2 ]]; then
    SHORT_VAL=$(echo "$value" | cut -c1-80)
    echo "[TS-13] Style string duplicated ${count} times: ${SHORT_VAL}..."
    grep -F "$value" "$STYLE_DUPS" | cut -d: -f1 | sort -u | sed 's/^/  - /'
    echo "  Remediation: 提取到共享样式常量文件（如 styles/constants.ts）"
    echo ""
    ISSUES=$((ISSUES + 1))
  fi
done
rm -f "$STYLE_DUPS" "$STYLE_VALUES"

# --- 总结 ---
echo "=== Summary: ${ISSUES} component/hook duplication issues found ==="

if [[ "$STRICT" == "true" && "$ISSUES" -gt 0 ]]; then
  exit 1
fi

exit 0

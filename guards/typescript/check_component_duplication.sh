#!/usr/bin/env bash
# VibeGuard Guard: check_component_duplication.sh (TS-13)
# Detect function-level duplication of React components and Hooks (different names and same functions)
#
# Usage:
#   bash check_component_duplication.sh [project_dir]
#   bash check_component_duplication.sh --strict [project_dir]
#
# Detection rules:
# 1. Duplication of UI primitives: multiple files define the FormField pattern of <label> + children + required
# 2. Table sorting is repeated: multiple files each implement useState(sort) + <table> mode
# 3. Query Hook template duplication: multiple use*Hook duplication useQuery → standardized return structure
# 4. Duplication of style constants: Multiple files define the same className/style string

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

# --- Check 1: FormField pattern duplication ---
# Detect component definition files that contain both <label and {children} (UI primitive feature)
echo "--- Checking FormField-like pattern duplication ---"

FORMFIELD_FILES=$(mktemp)
list_ts_files "${TARGET_DIR}" | filter_non_test | while IFS= read -r f; do
  if [[ -f "$f" ]]; then
    has_label=$(grep -cE '<label' "$f" 2>/dev/null || true)
    has_children=$(grep -cE '\{children\}|\{props\.children\}' "$f" 2>/dev/null || true)
    # Only match prop-level required (exclude HTML native <input required>)
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
  echo "Remediation: Extract to components/ui/FormField.tsx, other files are changed to import"
  echo ""
  ISSUES=$((ISSUES + 1))
elif [[ "$FORMFIELD_COUNT" -ge 2 ]]; then
  echo "[INFO] FormField-like pattern found in ${FORMFIELD_COUNT} files (monitor for 3rd occurrence)"
  sed 's/^/  - /' "$FORMFIELD_FILES"
  echo ""
fi
rm -f "$FORMFIELD_FILES"

# --- Check 2: Duplicate table sort pattern ---
# Detect components that contain both useState+sort and <table/<th (sort table feature)
echo "--- Checking table sort pattern duplication ---"

SORT_TABLE_FILES=$(mktemp)
list_ts_files "${TARGET_DIR}" | filter_non_test | while IFS= read -r f; do
  if [[ -f "$f" ]]; then
    # Tighten: require useState + sort related state, exclude sortKey in API parameters
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
  echo "Remediation: extracted to components/ui/DataTable.tsx, abstract sorting logic to hooks/useTableSort.ts"
  echo ""
  ISSUES=$((ISSUES + 1))
fi
rm -f "$SORT_TABLE_FILES"

# --- Check 3: Query Hook template duplication ---
# Detect multiple custom Hook files containing the same useQuery + standardized return pattern
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
# Increase the threshold: 3 → 4 to reduce false positives in standard useQuery mode
if [[ "$QUERY_COUNT" -ge 4 ]]; then
  echo "[TS-13] Query hook template pattern found in ${QUERY_COUNT} files (>=3 = must abstract):"
  sed 's/^/  - /' "$QUERY_HOOK_FILES"
  echo "Remediation: Extract public useQueryTemplate<T> hook, parameterized queryKey/queryFn/return type"
  echo ""
  ISSUES=$((ISSUES + 1))
elif [[ "$QUERY_COUNT" -ge 2 ]]; then
  echo "[INFO] Query hook template found in ${QUERY_COUNT} files (monitor for 3rd occurrence)"
  sed 's/^/  - /' "$QUERY_HOOK_FILES"
  echo ""
fi
rm -f "$QUERY_HOOK_FILES"

# --- Check 4: Duplicate style constant ---
# Detect if the same long className string appears in multiple files
echo "--- Checking duplicate style constants ---"

STYLE_DUPS=$(mktemp)
list_ts_files "${TARGET_DIR}" | filter_non_test | while IFS= read -r f; do
  if [[ -f "$f" ]]; then
    # Extract className/class string value with length >= 60
    grep -oE "(className|class|Style)\s*[:=]\s*['\"][^'\"]{60,}['\"]" "$f" 2>/dev/null \
      | sed "s/^/${f}:/" || true
  fi
done | sort -t: -k2 > "$STYLE_DUPS"

#Extract duplicate style values
STYLE_VALUES=$(mktemp)
cut -d: -f2- "$STYLE_DUPS" | sort | uniq -c | sort -rn | while read -r count value; do
  if [[ "$count" -ge 2 ]]; then
    SHORT_VAL=$(echo "$value" | cut -c1-80)
    echo "[TS-13] Style string duplicated ${count} times: ${SHORT_VAL}..."
    grep -F "$value" "$STYLE_DUPS" | cut -d: -f1 | sort -u | sed 's/^/  - /'
    echo "Remediation: Extract to shared style constant file (such as styles/constants.ts)"
    echo ""
    ISSUES=$((ISSUES + 1))
  fi
done
rm -f "$STYLE_DUPS" "$STYLE_VALUES"

# --- Summarize ---
echo "=== Summary: ${ISSUES} component/hook duplication issues found ==="

if [[ "$STRICT" == "true" && "$ISSUES" -gt 0 ]]; then
  exit 1
fi

exit 0

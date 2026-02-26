#!/usr/bin/env bash
# VibeGuard Guard: check_duplicate_constants.sh
# 检测 TypeScript/JavaScript 项目中跨文件的常量和类型重复定义
#
# 用法:
#   bash check_duplicate_constants.sh [project_dir]
#   bash check_duplicate_constants.sh --strict [project_dir]
#
# 检测规则:
#   1. const XXX = [...] 在多个文件中定义
#   2. type/interface XXX 在多个文件中定义
#   3. 同名函数在多个非测试文件中定义

set -euo pipefail

STRICT=false
PROJECT_DIR=""

for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=true ;;
    *) PROJECT_DIR="$arg" ;;
  esac
done

if [[ -z "$PROJECT_DIR" ]]; then
  PROJECT_DIR=$(pwd)
fi

SRC_DIR="${PROJECT_DIR}/src"
if [[ ! -d "$SRC_DIR" ]]; then
  echo "[PASS] No src/ directory found"
  exit 0
fi

ISSUES=0

echo "=== VibeGuard: Duplicate Constants Check ==="
echo ""

# --- 检查 1: const 常量重复 ---
echo "--- Checking duplicate const definitions ---"

# 提取所有 export const XXX 定义
CONST_DEFS=$(grep -rn "export const [A-Z][A-Z_]*\b" "$SRC_DIR" \
  --include="*.ts" --include="*.tsx" \
  | grep -v node_modules \
  | grep -v ".test." \
  | grep -v ".spec." \
  | grep -v "/test/" \
  | sed 's/:.*//' \
  | sort || true)

# 提取常量名并检查重复
grep -roh "export const [A-Z][A-Z_]*" "$SRC_DIR" \
  --include="*.ts" --include="*.tsx" \
  | grep -v node_modules \
  | sort | uniq -c | sort -rn \
  | while read -r count name; do
    if [[ "$count" -gt 1 ]]; then
      CONST_NAME=$(echo "$name" | sed 's/export const //')
      FILES=$(grep -rln "export const ${CONST_NAME}\b" "$SRC_DIR" \
        --include="*.ts" --include="*.tsx" \
        | grep -v node_modules \
        | grep -v ".test." \
        | grep -v ".spec." || true)
      FILE_COUNT=$(echo "$FILES" | grep -c . || true)
      if [[ "$FILE_COUNT" -gt 1 ]]; then
        echo "[DUP-CONST] ${CONST_NAME} defined in ${FILE_COUNT} files:"
        echo "$FILES" | sed 's/^/  - /'
        echo "  Remediation: 保留一处定义，其他文件改为 import"
        echo ""
        ISSUES=$((ISSUES + 1))
      fi
    fi
  done

# --- 检查 2: type/interface 重复 ---
echo "--- Checking duplicate type/interface definitions ---"

grep -roh "export \(type\|interface\) [A-Z][A-Za-z]*" "$SRC_DIR" \
  --include="*.ts" --include="*.tsx" \
  | grep -v node_modules \
  | sort | uniq -c | sort -rn \
  | while read -r count name; do
    if [[ "$count" -gt 1 ]]; then
      TYPE_NAME=$(echo "$name" | sed 's/export \(type\|interface\) //')
      FILES=$(grep -rln "export \(type\|interface\) ${TYPE_NAME}\b" "$SRC_DIR" \
        --include="*.ts" --include="*.tsx" \
        | grep -v node_modules \
        | grep -v ".test." || true)
      FILE_COUNT=$(echo "$FILES" | grep -c . || true)
      if [[ "$FILE_COUNT" -gt 1 ]]; then
        echo "[DUP-TYPE] ${TYPE_NAME} defined in ${FILE_COUNT} files:"
        echo "$FILES" | sed 's/^/  - /'
        echo "  Remediation: 集中到 src/types/ 下统一导出"
        echo ""
        ISSUES=$((ISSUES + 1))
      fi
    fi
  done

# --- 检查 3: 同名工具函数重复 ---
echo "--- Checking duplicate function definitions ---"

grep -roh "function [a-z][A-Za-z]*" "$SRC_DIR" \
  --include="*.ts" --include="*.tsx" \
  | grep -v node_modules \
  | sort | uniq -c | sort -rn \
  | while read -r count name; do
    if [[ "$count" -ge 3 ]]; then
      FUNC_NAME=$(echo "$name" | sed 's/function //')
      FILES=$(grep -rln "function ${FUNC_NAME}\b" "$SRC_DIR" \
        --include="*.ts" --include="*.tsx" \
        | grep -v node_modules \
        | grep -v ".test." \
        | grep -v ".spec." || true)
      FILE_COUNT=$(echo "$FILES" | grep -c . || true)
      if [[ "$FILE_COUNT" -ge 3 ]]; then
        echo "[DUP-FUNC] ${FUNC_NAME} defined in ${FILE_COUNT} files (>=3 = must abstract):"
        echo "$FILES" | sed 's/^/  - /'
        echo "  Remediation: 提取到 src/lib/utils/ 下共享"
        echo ""
        ISSUES=$((ISSUES + 1))
      fi
    fi
  done

echo "=== Summary: ${ISSUES} duplicate issues found ==="

if [[ "$STRICT" == "true" ]] && [[ "$ISSUES" -gt 0 ]]; then
  exit 1
fi

exit 0

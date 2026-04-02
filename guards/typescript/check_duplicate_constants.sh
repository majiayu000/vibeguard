#!/usr/bin/env bash
# VibeGuard Guard: check_duplicate_constants.sh
# Detect repeated definitions of constants and types across files in TypeScript/JavaScript projects
#
# Usage:
#   bash check_duplicate_constants.sh [project_dir]
#   bash check_duplicate_constants.sh --strict [project_dir]
#
# Detection rules:
# 1. const XXX = [...] defined in multiple files
# 2. type/interface XXX is defined in multiple files
# 3. Functions with the same name are defined in multiple non-test files

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

# --- Check 1: const constant duplication ---
echo "--- Checking duplicate const definitions ---"

# Extract all export const XXX definitions
CONST_DEFS=$(grep -rn "export const [A-Z][A-Z_]*\b" "$SRC_DIR" \
  --include="*.ts" --include="*.tsx" \
  | grep -v node_modules \
  | grep -v ".test." \
  | grep -v ".spec." \
  | grep -v "/test/" \
  | sed 's/:.*//' \
  | sort || true)

# Extract constant names and check for duplicates
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
        echo "Remediation: Keep one definition and change other files to import"
        echo ""
        ISSUES=$((ISSUES + 1))
      fi
    fi
  done

# --- Check 2: type/interface duplicate ---
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
        echo "Remediation: centralized and exported under src/types/"
        echo ""
        ISSUES=$((ISSUES + 1))
      fi
    fi
  done

# --- Check 3: Duplicate tool function with the same name ---
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
        echo "Remediation: Extract to share under src/lib/utils/"
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

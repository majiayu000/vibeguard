#!/usr/bin/env bash
# VibeGuard Guard — AI code garbage detection
#
# Detect common AI garbage patterns:
# - unused import
# - Empty catch/except block
# - TODO/FIXME not processed for more than 30 days
# - Dead code markers (unreachable, never)
# - Legacy debugging code (console.log, print, dbg!)
#
# Usage:
# bash check_code_slop.sh [target_dir] # Scan the specified directory
# bash check_code_slop.sh # Scan the current directory

set -euo pipefail

TARGET_DIR="${1:-.}"
ISSUES=0

yellow() { printf '\033[33m[SLOP] %s\033[0m\n' "$1"; }
red() { printf '\033[31m[SLOP] %s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }

#Exclude directories
EXCLUDE="--exclude-dir=node_modules --exclude-dir=.git --exclude-dir=target --exclude-dir=dist --exclude-dir=build --exclude-dir=__pycache__ --exclude-dir=.venv --exclude-dir=vendor"

echo "Scan directory: ${TARGET_DIR}"
echo "---"

# 1. Empty catch/except block
echo "Check for empty exception handling block..."
EMPTY_CATCH=$(grep -rn $EXCLUDE \
  -E '(catch\s*\([^)]*\)\s*\{\s*\}|except(\s+\w+)?:\s*$|except.*:\s*pass\s*$)' \
  "$TARGET_DIR" --include='*.py' --include='*.ts' --include='*.js' --include='*.tsx' --include='*.jsx' \
  2>/dev/null || true)
if [[ -n "$EMPTY_CATCH" ]]; then
  COUNT=$(echo "$EMPTY_CATCH" | wc -l | tr -d ' ')
  red "Empty exception handling block: ${COUNT}"
  echo "$EMPTY_CATCH" | head -5
  [[ "$COUNT" -gt 5 ]] && echo " ... and $((COUNT - 5))"
  ISSUES=$((ISSUES + COUNT))
fi

# 2. Legacy debugging code
echo "Check legacy debugging code..."
DEBUG_CODE=$(grep -rn $EXCLUDE \
  -E '^\s*(console\.(log|debug|info)\(|print\(|println!\(|dbg!\(|puts |p |pp )' \
  "$TARGET_DIR" --include='*.py' --include='*.ts' --include='*.js' --include='*.tsx' --include='*.jsx' --include='*.rs' --include='*.rb' --include='*.go' \
  2>/dev/null | grep -v '// keep' | grep -v '# keep' | grep -v 'logger\.' || true)
if [[ -n "$DEBUG_CODE" ]]; then
  COUNT=$(echo "$DEBUG_CODE" | wc -l | tr -d ' ')
  yellow "Legacy debugging code: at ${COUNT}"
  echo "$DEBUG_CODE" | head -5
  [[ "$COUNT" -gt 5 ]] && echo " ... and $((COUNT - 5))"
  ISSUES=$((ISSUES + COUNT))
fi

# 3. Expired TODO/FIXME (git blame check date)
echo "Check expired TODO/FIXME..."
TODOS=$(grep -rn $EXCLUDE \
  -E '(TODO|FIXME|HACK|XXX)\b' \
  "$TARGET_DIR" --include='*.py' --include='*.ts' --include='*.js' --include='*.tsx' --include='*.jsx' --include='*.rs' --include='*.go' \
  2>/dev/null || true)
if [[ -n "$TODOS" ]]; then
  STALE=0
  CUTOFF=$(date -v-30d +%s 2>/dev/null || date -d "30 days ago" +%s 2>/dev/null || echo "0")
  while IFS= read -r line; do
    FILE=$(echo "$line" | cut -d: -f1)
    LINE_NUM=$(echo "$line" | cut -d: -f2)
    if [[ -f "$FILE" ]] && git log -1 --format=%at -L "${LINE_NUM},${LINE_NUM}:${FILE}" 2>/dev/null | head -1 | grep -qE '^[0-9]+$'; then
      COMMIT_TS=$(git log -1 --format=%at -L "${LINE_NUM},${LINE_NUM}:${FILE}" 2>/dev/null | head -1)
      if [[ "$COMMIT_TS" -lt "$CUTOFF" ]] 2>/dev/null; then
        STALE=$((STALE + 1))
      fi
    fi
  done <<< "$(echo "$TODOS" | head -20)"
  if [[ "$STALE" -gt 0 ]]; then
    yellow "Expired TODO/FIXME (>30 days): ${STALE}"
    ISSUES=$((ISSUES + STALE))
  fi
  echo "TODO/FIXME total: $(echo "$TODOS" | wc -l | tr -d ' ')"
fi

# 4. Dead code marking
echo "Check for dead code markers..."
DEAD_CODE=$(grep -rn $EXCLUDE \
  -E '(unreachable!|todo!|unimplemented!|#\[allow\(dead_code\)\]|// @ts-ignore|# type: ignore|# noqa)' \
  "$TARGET_DIR" --include='*.py' --include='*.ts' --include='*.js' --include='*.rs' \
  2>/dev/null || true)
if [[ -n "$DEAD_CODE" ]]; then
  COUNT=$(echo "$DEAD_CODE" | wc -l | tr -d ' ')
  yellow "Dead code/suppression flag: ${COUNT}"
  echo "$DEAD_CODE" | head -5
  [[ "$COUNT" -gt 5 ]] && echo " ... and $((COUNT - 5))"
  ISSUES=$((ISSUES + COUNT))
fi

# 5. Very long files (> 300 lines)
echo "Check for very long files..."
LONG_FILES=$(find "$TARGET_DIR" \
  -name '*.py' -o -name '*.ts' -o -name '*.js' -o -name '*.tsx' -o -name '*.rs' -o -name '*.go' \
  2>/dev/null | while read -r f; do
    [[ "$f" == *node_modules* || "$f" == *target* || "$f" == *dist* || "$f" == *.git* ]] && continue
    LINES=$(wc -l < "$f" 2>/dev/null || echo 0)
    [[ "$LINES" -gt 300 ]] && echo " ${f}: ${LINES} lines"
  done || true)
if [[ -n "$LONG_FILES" ]]; then
  COUNT=$(echo "$LONG_FILES" | wc -l | tr -d ' ')
  yellow "Extra long files (>300 lines): ${COUNT}"
  echo "$LONG_FILES" | head -5
  ISSUES=$((ISSUES + COUNT))
fi

echo ""
echo "---"
if [[ "$ISSUES" -gt 0 ]]; then
  red "${ISSUES} garbage issues found"
  exit 1
else
  green "No code garbage found"
  exit 0
fi

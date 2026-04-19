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
# bash check_code_slop.sh [target_dir]                  # Scan target dir (default ".")
# bash check_code_slop.sh --include-fixtures [target]   # Include tests/fixtures in scan
# bash check_code_slop.sh --strict-repo [target]        # Disable repo-local noise exclusions

set -euo pipefail

TARGET_DIR="."
ISSUES=0

yellow() { printf '\033[33m[SLOP] %s\033[0m\n' "$1"; }
red() { printf '\033[31m[SLOP] %s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }

usage() {
  cat <<'EOF'
Usage: check_code_slop.sh [--include-fixtures] [--strict-repo] [target_dir]
  --include-fixtures  Include tests/fixtures in scanning
  --strict-repo       Disable repository-local noise exclusions (.claude/.vibeguard/.omx)

Default behavior:
  - Always excludes: node_modules .git target dist build __pycache__ .venv vendor
  - Unless --strict-repo: also excludes .claude .vibeguard .omx fixtures
  - Auto-detect: when scanning the vibeguard repo itself, additionally excludes
    workflows data scripts eval (these contain intentional patterns for CI/docs)
EOF
}

INCLUDE_FIXTURES=false
STRICT_REPO=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-fixtures)
      INCLUDE_FIXTURES=true
      shift
      ;;
    --strict-repo)
      STRICT_REPO=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      red "Unknown option: $1"
      usage
      exit 2
      ;;
    *)
      TARGET_DIR="$1"
      shift
      ;;
  esac
done

# Exclude directories (base names for grep/find pruning)
EXCLUDE_DIRS=(node_modules .git target dist build __pycache__ .venv vendor)
if [[ "$STRICT_REPO" != true ]]; then
  EXCLUDE_DIRS+=(.claude .vibeguard .omx)
fi
if [[ "$INCLUDE_FIXTURES" != true && "$STRICT_REPO" != true ]]; then
  EXCLUDE_DIRS+=(fixtures)
fi

# Auto-detect vibeguard repo: when the target directory contains the marker file
# .vibeguard-doc-paths-allowlist AND guards/ + hooks/ dirs, we know we are scanning
# the vibeguard repo itself.  In that case, exclude directories whose files contain
# intentional slop-like patterns (CI scripts with grep examples, doc fixtures, eval
# test data, workflow YAML with shell snippets).  Use --strict-repo to disable.
if [[ "$STRICT_REPO" != true ]] && [[ -f "${TARGET_DIR%/}/.vibeguard-doc-paths-allowlist" ]] \
  && [[ -d "${TARGET_DIR%/}/guards" ]] && [[ -d "${TARGET_DIR%/}/hooks" ]]; then
  EXCLUDE_DIRS+=(workflows data scripts eval)
fi

EXCLUDE_ARGS=()
for dir in "${EXCLUDE_DIRS[@]}"; do
  EXCLUDE_ARGS+=("--exclude-dir=${dir}")
done

echo "Scan directory: ${TARGET_DIR}"
echo "---"

# 1. Empty catch/except block
echo "Check for empty exception handling block..."
EMPTY_CATCH=$(grep -rn "${EXCLUDE_ARGS[@]}" \
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
DEBUG_CODE=$(grep -rn "${EXCLUDE_ARGS[@]}" \
  -E '^\s*(console\.(log|debug|info)\(|print\(|println!\(|dbg!\(|puts |p |pp )' \
  "$TARGET_DIR" --include='*.py' --include='*.ts' --include='*.js' --include='*.tsx' --include='*.jsx' --include='*.rs' --include='*.rb' --include='*.go' \
  2>/dev/null | grep -v '// keep' | grep -v '# keep' | grep -v 'logger\.') || true
if [[ -n "$DEBUG_CODE" ]]; then
  COUNT=$(echo "$DEBUG_CODE" | wc -l | tr -d ' ')
  yellow "Legacy debug code: ${COUNT}"
  echo "$DEBUG_CODE" | head -5
  [[ "$COUNT" -gt 5 ]] && echo " ... and $((COUNT - 5))"
  ISSUES=$((ISSUES + COUNT))
fi

# 3. Expired TODO/FIXME (git blame check date)
echo "Check expired TODO/FIXME..."
TODOS=$(grep -rn "${EXCLUDE_ARGS[@]}" \
  -E '(TODO|FIXME|HACK|XXX)\b' \
  "$TARGET_DIR" --include='*.py' --include='*.ts' --include='*.js' --include='*.tsx' --include='*.jsx' --include='*.rs' --include='*.go' \
  2>/dev/null || true)
if [[ -n "$TODOS" ]]; then
  TODO_SCAN_LIMIT="${VIBEGUARD_TODO_SCAN_LIMIT:-20}"
  if ! [[ "$TODO_SCAN_LIMIT" =~ ^[0-9]+$ ]] || [[ "$TODO_SCAN_LIMIT" -le 0 ]]; then
    TODO_SCAN_LIMIT=20
  fi
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
  done <<< "$(echo "$TODOS" | head -n "$TODO_SCAN_LIMIT")"
  if [[ "$STALE" -gt 0 ]]; then
    yellow "Expired TODO/FIXME (>30 days): ${STALE}"
    ISSUES=$((ISSUES + STALE))
  fi
  TODO_TOTAL=$(echo "$TODOS" | wc -l | tr -d ' ')
  echo "TODO/FIXME total: ${TODO_TOTAL}"
  if [[ "$TODO_TOTAL" -gt "$TODO_SCAN_LIMIT" ]]; then
    echo "TODO/FIXME stale-date scan capped at ${TODO_SCAN_LIMIT} matches (set VIBEGUARD_TODO_SCAN_LIMIT to override)"
  fi
fi

# 4. Dead code marking
echo "Check for dead code markers..."
DEAD_CODE=$(grep -rn "${EXCLUDE_ARGS[@]}" \
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
PRUNE_EXPR=()
for dir in "${EXCLUDE_DIRS[@]}"; do
  [[ ${#PRUNE_EXPR[@]} -gt 0 ]] && PRUNE_EXPR+=(-o)
  PRUNE_EXPR+=(-name "$dir")
done

LONG_FILES=$(find "$TARGET_DIR" \
  \( -type d \( "${PRUNE_EXPR[@]}" \) -prune \) -o \
  \( -type f \( -name '*.py' -o -name '*.ts' -o -name '*.js' -o -name '*.tsx' -o -name '*.rs' -o -name '*.go' \) -print \) \
  2>/dev/null | while read -r f; do
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

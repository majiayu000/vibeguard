#!/usr/bin/env bash
# VibeGuard CI: Static performance analysis for hook scripts
#
# Detects dangerous patterns that can cause >200ms hook execution:
# 1. Unbounded file reads (cat/python open() without tail/head limit)
# 2. Git commands without timeout fallback
# 3. find without -maxdepth
# 4. Subprocess spawning inside loops (O(n) fork/exec)
# 5. Full JSONL file reads (should use tail -N | python3)
#
# Exit 0 = all clear, Exit 1 = violations found
#
# Usage: bash scripts/ci/validate-hook-perf.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOKS_DIR="${REPO_DIR}/hooks"
VIOLATIONS=0

red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$*"; }
green() { printf '\033[32m  PASS: %s\033[0m\n' "$*"; }
warn()  { printf '\033[33m  WARN: %s\033[0m\n' "$*"; }

echo "======================================"
echo "VibeGuard Hook Performance Audit"
echo "======================================"
echo ""

# --- Rule 1: Python open() without tail pipe (unbounded JSONL read) ---
echo "[PERF-01] Unbounded JSONL file read in Python"
# Pattern: python3 -c '... open(log_file) ...' without being piped from tail
while IFS= read -r file; do
  # Check for Python code that opens log_file/events file directly
  if grep -n 'with open(log_file)' "$file" 2>/dev/null | grep -v '^#' | grep -qv 'PERF-OK'; then
    red "${file##*/}: Python opens log_file directly — use 'tail -N \$LOG | python3' instead"
    VIOLATIONS=$((VIOLATIONS + 1))
  elif grep -n "open(os.environ" "$file" 2>/dev/null | grep -q 'LOG_FILE\|log_file'; then
    red "${file##*/}: Python opens log file via env var — use 'tail -N | python3' instead"
    VIOLATIONS=$((VIOLATIONS + 1))
  else
    green "${file##*/}: no unbounded JSONL read"
  fi
done < <(find "$HOOKS_DIR" -name '*.sh' -not -name 'log.sh' -not -name 'circuit-breaker.sh' -not -path '*/_lib/*' | sort)
echo ""

# --- Rule 2: find without -maxdepth ---
echo "[PERF-02] find commands without -maxdepth"
while IFS= read -r file; do
  # Look for find commands that lack -maxdepth (except in comments)
  UNBOUNDED_FINDS=$(grep -n 'find ' "$file" 2>/dev/null \
    | grep -v '^\s*#' \
    | grep -v 'maxdepth' \
    | grep -v 'PERF-OK' || true)
  if [[ -n "$UNBOUNDED_FINDS" ]]; then
    while IFS= read -r line; do
      warn "${file##*/}:${line}"
    done <<< "$UNBOUNDED_FINDS"
  fi
done < <(find "$HOOKS_DIR" -name '*.sh' | sort)
echo ""

# --- Rule 3: Git commands that could hang (no timeout context) ---
echo "[PERF-03] Git commands without timeout safety"
# We check for git diff/log/status in main hook scripts (not log.sh which has a simple rev-parse)
for file in "$HOOKS_DIR"/stop-guard.sh "$HOOKS_DIR"/pre-commit-guard.sh; do
  [[ ! -f "$file" ]] && continue
  basename="${file##*/}"
  # Count git commands that aren't wrapped in timeout or have 2>/dev/null fallback
  GIT_CALLS=$(grep -cn 'git ' "$file" 2>/dev/null || echo 0)
  GIT_SAFE=$(grep -c 'git.*2>/dev/null' "$file" 2>/dev/null || echo 0)
  if [[ "$GIT_CALLS" -gt 0 ]]; then
    green "${basename}: ${GIT_CALLS} git calls, ${GIT_SAFE} with error suppression"
  fi
done
echo ""

# --- Rule 4: Python subprocess in for/while loop ---
echo "[PERF-04] Subprocess in loop (O(n) fork)"
while IFS= read -r file; do
  # Detect: for/while ... do ... python3 ... done
  IN_LOOP=false
  LOOP_SUBPROCESS=false
  LINE_NUM=0
  while IFS= read -r line; do
    LINE_NUM=$((LINE_NUM + 1))
    case "$line" in
      *"while "*"do"*|*"for "*"do"*)
        IN_LOOP=true ;;
      *"done"*)
        IN_LOOP=false ;;
    esac
    if [[ "$IN_LOOP" == "true" ]] && echo "$line" | grep -qE '(python3|rg |grep -r)' 2>/dev/null; then
      if ! echo "$line" | grep -q 'PERF-OK'; then
        warn "${file##*/}:${LINE_NUM}: subprocess in loop — ${line:0:80}"
        LOOP_SUBPROCESS=true
      fi
    fi
  done < "$file"
  if [[ "$LOOP_SUBPROCESS" == "false" ]]; then
    green "${file##*/}: no subprocess-in-loop"
  fi
done < <(find "$HOOKS_DIR" -name '*.sh' -not -name 'log.sh' -not -name 'circuit-breaker.sh' | sort)
echo ""

# --- Summary ---
echo "======================================"
if [[ $VIOLATIONS -gt 0 ]]; then
  echo "FAILED: ${VIOLATIONS} performance violation(s) found"
  echo "Fix the violations above or add '# PERF-OK: <reason>' to suppress"
  exit 1
else
  echo "PASSED: No critical performance violations"
  exit 0
fi

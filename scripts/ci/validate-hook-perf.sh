#!/usr/bin/env bash
# VibeGuard CI: Static performance analysis for hook scripts
#
# Detects dangerous patterns that can cause hook latency regressions:
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
HOOKS_DIR="${VIBEGUARD_HOOKS_DIR:-${REPO_DIR}/hooks}"
VIOLATIONS=0

red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$*"; }
green() { printf '\033[32m  PASS: %s\033[0m\n' "$*"; }
warn()  { printf '\033[33m  WARN: %s\033[0m\n' "$*"; }

perf_ok_nearby() {
  local file="$1"
  local line_no="$2"
  local start=1
  if [[ "$line_no" -gt 2 ]]; then
    start=$((line_no - 2))
  fi
  sed -n "${start},${line_no}p" "$file" 2>/dev/null | grep -q 'PERF-OK'
}

line_is_comment() {
  local line="$1"
  [[ "${line}" =~ ^[[:space:]]*# ]]
}

line_is_output_literal() {
  local line="$1"
  [[ "${line}" =~ ^[[:space:]]*(echo|printf)[[:space:]] ]]
}

find_command_has_maxdepth() {
  local file="$1"
  local line_no="$2"
  local command="$3"
  local next_line next_no

  next_no="${line_no}"
  while [[ "${command}" =~ \\[[:space:]]*$ ]]; do
    next_no=$((next_no + 1))
    next_line="$(sed -n "${next_no}p" "${file}" 2>/dev/null || true)"
    command="${command%\\}${next_line}"
  done

  [[ "${command}" == *"-maxdepth"* ]]
}

git_command_is_safe() {
  local line="$1"

  # timeout-wrapped git calls have a bounded wall-clock budget.
  if printf '%s\n' "$line" | grep -Eq '(^|[[:space:];|&({])(gtimeout|timeout)[[:space:]][^;&|]*git[[:space:]]'; then
    return 0
  fi

  # Existing hooks rely on suppressed git failures when running outside a worktree
  # or against partially initialized repos.
  if [[ "$line" == *"2>/dev/null"* || "$line" == *"&>/dev/null"* || "$line" == *">/dev/null 2>&1"* ]]; then
    return 0
  fi

  # Explicit fallback keeps hook execution moving when git cannot answer.
  if [[ "$line" == *"|| true"* || "$line" == *"|| echo"* || "$line" == *"|| pwd"* ]]; then
    return 0
  fi

  return 1
}

echo "======================================"
echo "VibeGuard Hook Performance Audit"
echo "======================================"
echo ""

# --- Rule 1: Python open() without tail pipe (unbounded JSONL read) ---
echo "[PERF-01] Unbounded JSONL file read in Python"
# Pattern: python3 -c '... open(log_file) ...' without being piped from tail
while IFS= read -r file; do
  # Check for Python code that opens log_file/events file directly
  OPEN_VIOLATION=false
  while IFS=: read -r line_no line; do
    [[ -z "${line_no}" ]] && continue
    if ! line_is_comment "$line" && ! perf_ok_nearby "$file" "$line_no"; then
      OPEN_VIOLATION=true
    fi
  done < <(grep -n 'with open(log_file)' "$file" 2>/dev/null || true)
  if [[ "$OPEN_VIOLATION" == "true" ]]; then
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
    | grep -v '^[0-9]\+:[[:space:]]*#' \
    | grep -v 'maxdepth' \
    || true)
  if [[ -n "$UNBOUNDED_FINDS" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      line_no="${line%%:*}"
      command="${line#*:}"
      if find_command_has_maxdepth "$file" "$line_no" "$command"; then
        green "${file##*/}:${line_no}: bounded find"
      elif perf_ok_nearby "$file" "$line_no"; then
        green "${file##*/}:${line_no}: documented unbounded find"
      else
        red "${file##*/}:${line}"
        VIOLATIONS=$((VIOLATIONS + 1))
      fi
    done <<< "$UNBOUNDED_FINDS"
  fi
done < <(find "$HOOKS_DIR" -name '*.sh' | sort)
echo ""

# --- Rule 3: Git commands that could hang (no timeout context) ---
echo "[PERF-03] Git commands without timeout safety"
while IFS= read -r file; do
  UNSAFE_GIT=false
  while IFS=: read -r line_no line; do
    [[ -z "${line_no}" ]] && continue
    if line_is_comment "$line" || line_is_output_literal "$line"; then
      continue
    fi
    if perf_ok_nearby "$file" "$line_no"; then
      green "${file##*/}:${line_no}: documented git call"
    elif git_command_is_safe "$line"; then
      green "${file##*/}:${line_no}: bounded or error-suppressed git call"
    else
      red "${file##*/}:${line_no}: unsafe git call — ${line:0:80}"
      VIOLATIONS=$((VIOLATIONS + 1))
      UNSAFE_GIT=true
    fi
  done < <(grep -nE '(^|[^[:alnum:]_./-])git[[:space:]]+' "$file" 2>/dev/null || true)
  if [[ "$UNSAFE_GIT" == "false" ]]; then
    green "${file##*/}: no unsafe git calls"
  fi
done < <(find "$HOOKS_DIR" -maxdepth 1 -name '*.sh' | sort)
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
    if line_is_comment "$line"; then
      continue
    fi
    case "$line" in
      *"while "*"do"*|*"for "*"do"*)
        IN_LOOP=true ;;
      *"done"*)
        IN_LOOP=false ;;
    esac
    if [[ "$IN_LOOP" == "true" ]] && echo "$line" | grep -qE '(python3|rg |grep -r)' 2>/dev/null; then
      if ! perf_ok_nearby "$file" "$LINE_NUM"; then
        red "${file##*/}:${LINE_NUM}: subprocess in loop — ${line:0:80}"
        VIOLATIONS=$((VIOLATIONS + 1))
        LOOP_SUBPROCESS=true
      else
        green "${file##*/}:${LINE_NUM}: documented subprocess in loop"
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

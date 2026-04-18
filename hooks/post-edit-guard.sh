#!/usr/bin/env bash
# VibeGuard PostToolUse(Edit) Hook
#
# After editing the source code, check whether quality problems have been introduced:
# - Rust: Add unwrap()/expect() to non-test code
# - Rust: Added let _ = silently discard Result
# - General: Added hardcoded paths (.db/.sqlite)
#
# Output warning context, do not prevent operations (post-event reminder)
#
# Suppress single-line warnings: add the following line before the detected line:
#   // vibeguard-disable-next-line RS-03 -- reason   (Rust/TS/JS/Go)
#   # vibeguard-disable-next-line RS-03 -- reason    (Python/Shell)

set -euo pipefail

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/_lib/stub_detect.sh"
vg_start_timer
VG_EVENT_LOG_LIB="${VG_EVENT_LOG_LIB:-$(cd "$(dirname "$0")/_lib" && pwd)}"

INPUT=$(cat)

RESULT=$(echo "$INPUT" | vg_json_two_fields "tool_input.file_path" "tool_input.new_string")

FILE_PATH=$(echo "$RESULT" | head -1)
NEW_STRING=$(echo "$RESULT" | tail -n +2)

if [[ -z "$FILE_PATH" ]] || [[ -z "$NEW_STRING" ]]; then
  exit 0
fi

WARNINGS=""

# ---------------------------------------------------------------------------
# vg_filter_suppressed RULE_ID
# Reads NEW_STRING from stdin; outputs lines NOT suppressed by the rule.
# Suppression: a line is suppressed when the immediately preceding line
# contains "vibeguard-disable-next-line RULE_ID" (any comment prefix).
# Pure awk implementation — no Python subprocess overhead.
# ---------------------------------------------------------------------------
vg_filter_suppressed() {
  local rule="$1"
  # trisq passed via -v so that ''' never appears inside the single-quoted awk body.
  awk -v rule="$rule" -v trisq="'''" '
    BEGIN { suppress = 0; in_template = 0; in_triple_dq = 0; in_triple_sq = 0 }
    {
      # Record multiline-string state at the START of this line so a
      # disable comment that is itself inside a string is not honoured.
      start_in_ml = (in_template || in_triple_dq || in_triple_sq)

      # Track JS/TS template-literal depth via backtick parity.
      tmp = $0; n = gsub(/`/, "", tmp)
      if (n % 2 == 1) in_template = 1 - in_template

      # Track triple-double-quote multi-line strings (Python, Rust raw).
      tmp = $0; n = gsub(/"""/, "", tmp)
      if (n % 2 == 1) in_triple_dq = 1 - in_triple_dq

      # Track triple-single-quote multi-line strings (Python).
      tmp = $0; n = gsub(trisq, "", tmp)
      if (n % 2 == 1) in_triple_sq = 1 - in_triple_sq

      if (suppress) { suppress = 0; next }
      if (!start_in_ml &&
          $0 ~ "^[[:space:]]*(//|#)[[:space:]]*vibeguard-disable-next-line[[:space:]]+" rule "([[:space:]]|--|$)") {
        suppress = 1
      }
      print
    }
  '
}

# --- Rust inspection ---
if [[ "$FILE_PATH" == *.rs ]]; then
  #Exclude test files
  case "$FILE_PATH" in
    */tests/*|*_test.rs|*/test_*) ;;
    *)
      # [RS-03] Detect new unwrap()/expect()
      _RS03_FILTERED=$(echo "$NEW_STRING" | vg_filter_suppressed "RS-03")
      if echo "$_RS03_FILTERED" | grep -qE '\.(unwrap|expect)\(' 2>/dev/null; then
        # Exclude safe variants
        UNSAFE_COUNT=$(echo "$_RS03_FILTERED" | grep -cE '\.(unwrap|expect)\(' 2>/dev/null || true)
        SAFE_COUNT=$(echo "$_RS03_FILTERED" | grep -cE '\.(unwrap_or|unwrap_or_else|unwrap_or_default)\(' 2>/dev/null || true)
        REAL_COUNT=$((UNSAFE_COUNT - SAFE_COUNT))
        if [[ $REAL_COUNT -gt 0 ]]; then
          WARNINGS="${WARNINGS:+${WARNINGS}
---
}[RS-03] [review] [this-edit] OBSERVATION: ${REAL_COUNT} new unwrap()/expect() call(s) added
SCOPE: this-edit only — do not propagate changes beyond this edit, add error types, or change signatures
ACTION: REVIEW"
        fi
      fi
      # [RS-10] Detect silent discard Result (let _ = expr)
      SILENT_COUNT=$(echo "$NEW_STRING" | vg_filter_suppressed "RS-10" | grep -cE '^\s*let\s+_\s*=' 2>/dev/null; true)
      if [[ $SILENT_COUNT -gt 0 ]]; then
        WARNINGS="${WARNINGS:+${WARNINGS}
---
}[RS-10] [review] [this-edit] OBSERVATION: ${SILENT_COUNT} new let _ = silent discard(s) added
SCOPE: this-edit only — do not refactor calling code or add new error types
ACTION: REVIEW"
      fi
      ;;
  esac
fi

# --- JavaScript/TypeScript check: console.log/warn/error ---
case "$FILE_PATH" in
  *.ts|*.tsx|*.js|*.jsx)
    case "$FILE_PATH" in
      */tests/*|*_test.*|*.test.*|*.spec.*) ;;
      */debug.*|*/debug/*|*logger*|*logging*) ;;
      *)
        # CLI project allows console, skip (bin field / src/cli.* / scripts including cli)
        _PKG_DIR=$(dirname "$FILE_PATH")
        _IS_CLI=false
        while [[ "$_PKG_DIR" != "/" && "$_PKG_DIR" != "." ]]; do
          if [[ -f "$_PKG_DIR/package.json" ]]; then
            grep -qE '"bin"' "$_PKG_DIR/package.json" 2>/dev/null && _IS_CLI=true
            grep -qE '"[^"]*":\s*"[^"]*cli[^"]*"' "$_PKG_DIR/package.json" 2>/dev/null && _IS_CLI=true
          fi
          ls "$_PKG_DIR/src/cli."* "$_PKG_DIR/cli."* 2>/dev/null | grep -q . && _IS_CLI=true
          [[ "$_IS_CLI" == true ]] && break
          _PKG_DIR=$(dirname "$_PKG_DIR")
        done
        # It is a protocol standard practice to use console.error to output the MCP entry file to stderr, so skip it.
        if [[ "$_IS_CLI" == true ]]; then
          : # CLI project, console is the normal output mode
        elif [[ -f "$FILE_PATH" ]] && grep -qE '(StdioServerTransport|new Server\(|McpServer)' "$FILE_PATH" 2>/dev/null; then
          : # MCP entry file, skip console detection
        else
          CONSOLE_COUNT=$(echo "$NEW_STRING" | vg_filter_suppressed "DEBUG" | grep -cE '\bconsole\.(log|warn|error)\(' 2>/dev/null; true)
          if [[ $CONSOLE_COUNT -gt 0 ]]; then
            # Check the total number of console residues already in the file
            FILE_CONSOLE_TOTAL=0
            if [[ -f "$FILE_PATH" ]]; then
              FILE_CONSOLE_TOTAL=$(grep -cE '\bconsole\.(log|warn|error)\(' "$FILE_PATH" 2>/dev/null; true)
            fi
            if [[ $FILE_CONSOLE_TOTAL -ge 10 ]]; then
              WARNINGS="${WARNINGS:+${WARNINGS}
---
}[DEBUG] [review] [this-file] OBSERVATION: file has ${FILE_CONSOLE_TOTAL} console residuals and new ones are being added
FIX: Remove this console.log/warn/error call; keep only if this is intentional debug output
DO NOT: Create logger modules, modify other files, or fix console usage outside this file"
            else
              WARNINGS="${WARNINGS:+${WARNINGS}
---
}[DEBUG] [review] [this-edit] OBSERVATION: ${CONSOLE_COUNT} new console.log/warn/error call(s) added
FIX: Remove this console.log/warn/error call; keep only if this is a CLI project (check bin field in package.json)
DO NOT: Create new logger modules, modify other files, or fix console usage outside this edit"
            fi
          fi
        fi

        # [U-HARDCODE] Removed: signal-to-noise ratio is too low, enumeration assignment/React props/constant definition all false positives
        # See docs/known-false-positives.md#U-HARDCODE for details
        ;;
    esac
    ;;
esac

# --- Python check: print() statement ---
case "$FILE_PATH" in
  *.py)
    case "$FILE_PATH" in
      */tests/*|*test_*|*_test.py) ;;
      *)
        PRINT_COUNT=$(echo "$NEW_STRING" | vg_filter_suppressed "DEBUG" | grep -cE '^\s*print\(' 2>/dev/null; true)
        if [[ $PRINT_COUNT -gt 0 ]]; then
          WARNINGS="${WARNINGS:+${WARNINGS}
---
}[DEBUG] [review] [this-edit] OBSERVATION: ${PRINT_COUNT} new print() statement(s) added
FIX: Remove this print() call, or replace with logging.getLogger(__name__).debug() for permanent logging
DO NOT: Modify logging configuration or other files"
        fi
        ;;
    esac
    ;;
esac

# --- Generic check: hardcoded database path ---
if echo "$NEW_STRING" | vg_filter_suppressed "U-11" | grep -qE '"[^"]*\.(db|sqlite)"' 2>/dev/null; then
  case "$FILE_PATH" in
    */tests/*|*_test.*|*.test.*|*.spec.*) ;;
    *)
      WARNINGS="${WARNINGS:+${WARNINGS}
---
}[U-11] [review] [this-line] OBSERVATION: hardcoded database path (.db/.sqlite) detected
FIX: Extract to a shared default_db_path() function in core layer; use env var APP_DB_PATH for override
DO NOT: Refactor path functions, move code to another file, or change other hardcoded paths"
      ;;
  esac
fi

# --- Go check ---
case "$FILE_PATH" in
  *.go)
    case "$FILE_PATH" in
      *_test.go|*/vendor/*) ;;
      *)
        # [GO-01] Detect error and discard (exclude for range and map searches)
        ERR_DISCARD=$(echo "$NEW_STRING" | vg_filter_suppressed "GO-01" | grep -E '^\s*_\s*(,\s*_)?\s*[:=]+' 2>/dev/null \
          | grep -cvE '(for\s+.*range|,\s*(ok|found|exists)\s*:?=)' 2>/dev/null; true)
        if [[ $ERR_DISCARD -gt 0 ]]; then
          WARNINGS="${WARNINGS:+${WARNINGS}
---
}[GO-01] [auto-fix] [this-line] OBSERVATION: ${ERR_DISCARD} new error discard(s) (\"_ = ...\") added
FIX: Replace _ = fn() with err := fn(); if err != nil { return fmt.Errorf(\"context: %w\", err) }
DO NOT: Modify function signatures or upstream callers"
        fi
        # [GO-08] Detect defer inside loop
        DEFER_LOOP=$(echo "$NEW_STRING" | vg_filter_suppressed "GO-08" | awk '/^\s*for\s/ {in_loop=1} /^\s*defer\s/ && in_loop {count++} /^\s*\}/ {in_loop=0} END {print count+0}' 2>/dev/null; true)
        DEFER_LOOP="${DEFER_LOOP:-0}"
        if [[ $DEFER_LOOP -gt 0 ]]; then
          WARNINGS="${WARNINGS:+${WARNINGS}
---
}[GO-08] [review] [this-edit] OBSERVATION: defer inside a loop detected, may cause resource leak
FIX: Extract the loop body containing defer into a separate function
DO NOT: Extract to a separate file or refactor loop logic beyond the current edit"
        fi
        ;;
    esac
    ;;
esac

# --- Anti-Stub detection (GSD reference: Level 2 product verification Level 2 — Substantiveness) ---
STUB_WARNINGS=$(vg_detect_stubs "$FILE_PATH" "$NEW_STRING" --filter-suppressed)
if [[ -n "$STUB_WARNINGS" ]]; then
  WARNINGS="${WARNINGS:+${WARNINGS}
---
}${STUB_WARNINGS}"
fi

# --- Super large diff detection (possibly hallucinatory editing) ---
DIFF_LINES=$(echo "$NEW_STRING" | wc -l | tr -d ' ')
if [[ $DIFF_LINES -gt 200 ]]; then
  WARNINGS="${WARNINGS:+${WARNINGS}
---
}[LARGE-EDIT] [info] [this-edit] OBSERVATION: single edit contains ${DIFF_LINES} lines, exceeding 200-line threshold
FIX: Verify the edit content is correct and intentional
DO NOT: Take any action — this is informational only"
fi

# --- [U-16] File size guard: 800-line default limit with project exemptions ---
case "$FILE_PATH" in
  *.rs|*.ts|*.tsx|*.js|*.jsx|*.py|*.go)
    case "$FILE_PATH" in
      */tests/*|*_test.*|*.test.*|*.spec.*|*_test.rs|*/test_*) ;;
      *)
        if [[ -f "$FILE_PATH" ]]; then
          _U16_TOTAL=$(wc -l < "$FILE_PATH" | tr -d ' ')
          if [[ "$_U16_TOTAL" -gt 800 ]]; then
            _U16_LIMIT=800
            # Find project root for CLAUDE.md exemptions
            _U16_DIR="$FILE_PATH"
            while [[ "$_U16_DIR" != "/" ]]; do
              _U16_DIR=$(dirname "$_U16_DIR")
              [[ -d "$_U16_DIR/.git" ]] && break
            done
            if [[ "$_U16_DIR" != "/" && -f "$_U16_DIR/CLAUDE.md" ]]; then
              _U16_EXEMPT=$(VG_CLAUDE_MD="$_U16_DIR/CLAUDE.md" VG_FILE_PATH="$FILE_PATH" python3 -c '
import os, re
from pathlib import PurePath
claude_md = os.environ["VG_CLAUDE_MD"]
file_path = os.environ["VG_FILE_PATH"]
limit = 0
try:
    with open(claude_md) as f:
        for line in f:
            if "U-16 exempt" not in line:
                continue
            for pair in re.finditer(r"`([^`]+)`\s*→\s*(\d+)", line):
                pattern, lim = pair.group(1), int(pair.group(2))
                try:
                    if PurePath(file_path).match(pattern):
                        limit = max(limit, lim)
                except (ValueError, TypeError):
                    continue
except FileNotFoundError:
    pass
print(limit)
' 2>/dev/null | tr -d '[:space:]' || echo "0")
              _U16_EXEMPT="${_U16_EXEMPT:-0}"
              if [[ "$_U16_EXEMPT" -gt 0 ]]; then
                _U16_LIMIT="$_U16_EXEMPT"
              fi
            fi
            if [[ "$_U16_TOTAL" -gt "$_U16_LIMIT" ]]; then
              WARNINGS="${WARNINGS:+${WARNINGS}
---
}[U-16] [review] [this-file] OBSERVATION: file has ${_U16_TOTAL} lines, exceeding ${_U16_LIMIT}-line limit
FIX: Split into focused submodules by responsibility; plan as a separate task
DO NOT: Start splitting now — finish the current task first, then refactor"
            fi
          fi
        fi
        ;;
    esac
    ;;
esac

# --- Churn Detection (the same file is edited repeatedly → may be corrected in a loop) ---
#Grading upgrade: 5=reminder, 10=warning, 20+=forced stop
# Read only last 500 lines to avoid O(n) full-file scan on long sessions
CHURN_COUNT=$(tail -500 "$VIBEGUARD_LOG_FILE" 2>/dev/null \
  | if [[ -n "$_VG_HELPER" ]]; then
      "$_VG_HELPER" churn-count "$VIBEGUARD_SESSION_ID" "$FILE_PATH"
    else
      VG_FILE_PATH="$FILE_PATH" VG_SESSION="$VIBEGUARD_SESSION_ID" VG_EVENT_LOG_LIB="$VG_EVENT_LOG_LIB" python3 -c '
import sys, os
sys.path.insert(0, os.environ["VG_EVENT_LOG_LIB"])
from event_log import iter_events_from_stream

file_path = os.environ.get("VG_FILE_PATH", "")
session = os.environ.get("VG_SESSION", "")
count = 0
for e in iter_events_from_stream(sys.stdin.buffer):
    if e.get("session") == session and e.get("tool") == "Edit" and file_path in e.get("detail", ""):
        count += 1
print(count)
'
    fi 2>/dev/null | tr -d '[:space:]' || echo "0")
CHURN_COUNT="${CHURN_COUNT:-0}"

if [[ "$CHURN_COUNT" -ge 20 ]]; then
  WARNINGS="${WARNINGS:+${WARNINGS}
---
}[CHURN CRITICAL] [review] [this-file] OBSERVATION: ${FILE_PATH##*/} has been edited ${CHURN_COUNT} times — possible edit→fail→fix loop
FIX: Stop current direction, review full build output, re-examine root cause (W-02)
DO NOT: Continue editing this file until root cause is confirmed"
  vg_log "post-edit-guard" "Edit" "escalate" "churn ${CHURN_COUNT}x critical" "$FILE_PATH"
elif [[ "$CHURN_COUNT" -ge 10 ]]; then
  WARNINGS="${WARNINGS:+${WARNINGS}
---
}[CHURN WARNING] [info] [this-file] OBSERVATION: ${FILE_PATH##*/} has been edited ${CHURN_COUNT} times, possible correction loop
FIX: Run full build to see the complete picture, or use /vibeguard:learn to extract patterns
DO NOT: Take any action — monitor and decide whether to continue"
  vg_log "post-edit-guard" "Edit" "escalate" "churn ${CHURN_COUNT}x warning" "$FILE_PATH"
elif [[ "$CHURN_COUNT" -ge 5 ]]; then
  WARNINGS="${WARNINGS:+${WARNINGS}
---
}[CHURN] [info] [this-file] OBSERVATION: ${FILE_PATH##*/} has been edited ${CHURN_COUNT} times
FIX: Check if you are in a correction loop before continuing
DO NOT: Take any action — this is informational only"
  vg_log "post-edit-guard" "Edit" "correction" "churn ${CHURN_COUNT}x" "$FILE_PATH"
fi

# --- [W-15] Consecutive Edit Loop Detection ---
# Distinct from CHURN (counts total session edits, non-consecutive):
# Counts edits to SAME FILE with NO intervening edits to other files.
# 3+ consecutive same-file edits → low-info loop suspect (W-15).
# Note: W-15 spec also requires "±10 lines region" check; the event log does not
# capture line numbers, so this is a file-level proxy (coarser than full spec).
PAST_CONSECUTIVE=$(tail -200 "$VIBEGUARD_LOG_FILE" 2>/dev/null \
  | VG_FILE_PATH="$FILE_PATH" VG_SESSION="$VIBEGUARD_SESSION_ID" VG_EVENT_LOG_LIB="$VG_EVENT_LOG_LIB" python3 -c '
import sys, os
sys.path.insert(0, os.environ["VG_EVENT_LOG_LIB"])
from event_log import iter_events_from_stream

file_path = os.environ.get("VG_FILE_PATH", "")
session = os.environ.get("VG_SESSION", "")
edits = []
for e in iter_events_from_stream(sys.stdin.buffer):
    if (e.get("session") == session and e.get("tool") == "Edit"
            and e.get("hook") == "post-edit-guard"):
        edits.append(e.get("detail", "").split("||")[0].strip())
consec = 0
for ep in reversed(edits):
    if ep == file_path: consec += 1
    else: break
print(consec)
' 2>/dev/null | tr -d '[:space:]' || echo "0")
PAST_CONSECUTIVE="${PAST_CONSECUTIVE:-0}"

# Threshold: 2 past consecutive + this edit = 3 in a row → W-15 trigger
if [[ "$PAST_CONSECUTIVE" -ge 2 ]]; then
  TOTAL_CONSECUTIVE=$((PAST_CONSECUTIVE + 1))
  WARNINGS="${WARNINGS:+${WARNINGS}
---
}[W-15] [review] [this-file] OBSERVATION: ${TOTAL_CONSECUTIVE} consecutive edits to ${FILE_PATH##*/} with no edits to other files in between (low-info loop suspect)
FIX: Pause — are these ${TOTAL_CONSECUTIVE} edits solving the same problem? If change scope shrinks each round, report a blocker instead of continuing to round $((TOTAL_CONSECUTIVE + 1))
DO NOT: Toggle between equivalent rewrites; do not continue same-direction micro-tuning without reporting"
  vg_log "post-edit-guard" "Edit" "warn" "w15 consecutive ${TOTAL_CONSECUTIVE}x" "$FILE_PATH"
fi

if [[ -z "$WARNINGS" ]]; then
  vg_log "post-edit-guard" "Edit" "pass" "" "$FILE_PATH"
  exit 0
fi

# --- Escalation detection ---
# The same file is warned more than 3 times in the current log → upgrade to escalate
DECISION="warn"
# Read only last 500 lines to avoid O(n) full-file scan
WARN_COUNT_FOR_FILE=$(tail -500 "$VIBEGUARD_LOG_FILE" 2>/dev/null \
  | if [[ -n "$_VG_HELPER" ]]; then
      "$_VG_HELPER" warn-count "$VIBEGUARD_SESSION_ID" "$FILE_PATH"
    else
      VG_FILE_PATH="$FILE_PATH" VG_SESSION="$VIBEGUARD_SESSION_ID" VG_EVENT_LOG_LIB="$VG_EVENT_LOG_LIB" python3 -c '
import sys, os
sys.path.insert(0, os.environ["VG_EVENT_LOG_LIB"])
from event_log import iter_events_from_stream

file_path = os.environ.get("VG_FILE_PATH", "")
session = os.environ.get("VG_SESSION", "")
count = 0
for e in iter_events_from_stream(sys.stdin.buffer):
    if e.get("session") == session and e.get("hook") == "post-edit-guard" and e.get("decision") == "warn" and e.get("detail", "").split("||")[0].strip() == file_path:
        count += 1
print(count)
'
    fi 2>/dev/null | tr -d '[:space:]' || echo "0")
WARN_COUNT_FOR_FILE="${WARN_COUNT_FOR_FILE:-0}"

if [[ "$WARN_COUNT_FOR_FILE" -ge 3 ]]; then
  DECISION="escalate"
  WARNINGS="[ESCALATE] [review] [this-file] OBSERVATION: this file has triggered ${WARN_COUNT_FOR_FILE} warnings — user intervention recommended
FIX: Stop and review the warnings below before continuing
DO NOT: Continue editing this file without reviewing all warnings
---
${WARNINGS}"
fi

vg_log "post-edit-guard" "Edit" "$DECISION" "$WARNINGS" "$FILE_PATH"

# Output warnings (pass parameters through environment variables to avoid injection)
VG_WARNINGS="$WARNINGS" VG_DECISION="$DECISION" python3 -c '
import json, os
warnings = os.environ.get("VG_WARNINGS", "")
decision = os.environ.get("VG_DECISION", "warn")
prefix = "VIBEGUARD upgrade warning" if decision == "escalate" else "VIBEGUARD quality warning"
result = {
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": prefix + "：" + warnings
    }
}
print(json.dumps(result, ensure_ascii=False))
'

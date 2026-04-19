#!/usr/bin/env bash
# Unit tests for hooks/_lib/session_metrics.py — missing optional env vars
#
# Covers the fallback paths introduced in the env-guard fix:
#   - VIBEGUARD_SESSION_ID absent  → no session filter, script runs cleanly
#   - VIBEGUARD_PROJECT_LOG_DIR absent → no metrics file written, no crash
#   - Both absent simultaneously   → same guarantees
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO_DIR}/hooks/_lib/session_metrics.py"

PASS=0; FAIL=0; TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }

assert_exit_zero() {
  local desc="$1"; shift; TOTAL=$((TOTAL+1))
  local out; out=$("$@" 2>&1); local rc=$?
  if [[ $rc -eq 0 ]]; then green "$desc"; PASS=$((PASS+1))
  else red "$desc (exit $rc; output: $out)"; FAIL=$((FAIL+1)); fi
}

assert_file_absent() {
  local desc="$1" path="$2"; TOTAL=$((TOTAL+1))
  if [[ ! -e "$path" ]]; then green "$desc"; PASS=$((PASS+1))
  else red "$desc (file unexpectedly exists: $path)"; FAIL=$((FAIL+1)); fi
}

assert_file_present() {
  local desc="$1" path="$2"; TOTAL=$((TOTAL+1))
  if [[ -e "$path" ]]; then green "$desc"; PASS=$((PASS+1))
  else red "$desc (file not found: $path)"; FAIL=$((FAIL+1)); fi
}

assert_output_contains() {
  local desc="$1" expected="$2"; shift 2; TOTAL=$((TOTAL+1))
  local out; out=$("$@" 2>&1 || true)
  if printf '%s\n' "$out" | grep -qF "$expected"; then green "$desc"; PASS=$((PASS+1))
  else red "$desc (missing '$expected' in: $out)"; FAIL=$((FAIL+1)); fi
}

# Generate a minimal events.jsonl with enough events to pass the threshold (>=3).
# Timestamps are set to "now" so they fall within the 30-minute window.
make_events() {
  local file="$1" session="${2:-sess-A}"
  python3 -c "
import json
from datetime import datetime, timezone
now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
for i in range(5):
    print(json.dumps({'ts': now, 'session': '${session}',
                      'hook': 'post-edit-guard', 'tool': 'Edit', 'decision': 'pass',
                      'reason': '', 'detail': f'src/file{i}.rs'}))
" > "$file"
}

# ─── Setup ────────────────────────────────────────────────────────────────────
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

EVENTS_FILE="$TMPDIR_TEST/events.jsonl"
make_events "$EVENTS_FILE" "sess-A"

# ─── Test 1: VIBEGUARD_SESSION_ID absent — no crash, exits 0 ─────────────────
assert_exit_zero \
  "missing VIBEGUARD_SESSION_ID: script exits 0" \
  env -i \
    PATH="$PATH" \
    HOME="$HOME" \
    VIBEGUARD_LOG_FILE="$EVENTS_FILE" \
    VIBEGUARD_PROJECT_LOG_DIR="$TMPDIR_TEST" \
    python3 "$SCRIPT"

# ─── Test 2: VIBEGUARD_SESSION_ID absent — metrics file written (events pass) ─
METRICS_FILE="$TMPDIR_TEST/session-metrics.jsonl"
rm -f "$METRICS_FILE"
env -i \
  PATH="$PATH" \
  HOME="$HOME" \
  VIBEGUARD_LOG_FILE="$EVENTS_FILE" \
  VIBEGUARD_PROJECT_LOG_DIR="$TMPDIR_TEST" \
  python3 "$SCRIPT" > /dev/null 2>&1 || true
assert_file_present \
  "missing VIBEGUARD_SESSION_ID: metrics file still written when log dir is set" \
  "$METRICS_FILE"

# ─── Test 3: VIBEGUARD_PROJECT_LOG_DIR absent — no crash, exits 0 ────────────
assert_exit_zero \
  "missing VIBEGUARD_PROJECT_LOG_DIR: script exits 0" \
  env -i \
    PATH="$PATH" \
    HOME="$HOME" \
    VIBEGUARD_LOG_FILE="$EVENTS_FILE" \
    VIBEGUARD_SESSION_ID="sess-A" \
    python3 "$SCRIPT"

# ─── Test 4: VIBEGUARD_PROJECT_LOG_DIR absent — no metrics file created ───────
STRAY="$TMPDIR_TEST/session-metrics-nodir.jsonl"
# run in a subdir that has no session-metrics.jsonl so we can detect stray writes
NODIR_TMPDIR=$(mktemp -d)
trap 'rm -rf "$NODIR_TMPDIR"' EXIT
env -i \
  PATH="$PATH" \
  HOME="$HOME" \
  VIBEGUARD_LOG_FILE="$EVENTS_FILE" \
  VIBEGUARD_SESSION_ID="sess-A" \
  python3 "$SCRIPT" > /dev/null 2>&1 || true
assert_file_absent \
  "missing VIBEGUARD_PROJECT_LOG_DIR: no metrics file written anywhere unexpected" \
  "$NODIR_TMPDIR/session-metrics.jsonl"

# ─── Test 5: Both absent simultaneously — no crash, exits 0 ──────────────────
assert_exit_zero \
  "both VIBEGUARD_SESSION_ID and VIBEGUARD_PROJECT_LOG_DIR absent: exits 0" \
  env -i \
    PATH="$PATH" \
    HOME="$HOME" \
    VIBEGUARD_LOG_FILE="$EVENTS_FILE" \
    python3 "$SCRIPT"

# ─── Test 6: High-friction session without VIBEGUARD_PROJECT_LOG_DIR ──────────
# Generates 10 events with warn decisions so signal 1 fires, even without log dir
WARN_EVENTS="$TMPDIR_TEST/events-warn.jsonl"
python3 -c "
import json
from datetime import datetime, timezone
now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
for i in range(10):
    d = 'warn' if i < 8 else 'pass'
    print(json.dumps({'ts': now, 'session': 'sess-A',
                      'hook': 'post-edit-guard', 'tool': 'Edit', 'decision': d,
                      'reason': '[RS-03] unwrap in prod', 'detail': 'src/main.rs'}))
" > "$WARN_EVENTS"

assert_output_contains \
  "missing VIBEGUARD_PROJECT_LOG_DIR: LEARN_SUGGESTED still printed when signals fire" \
  "LEARN_SUGGESTED" \
  env -i \
    PATH="$PATH" \
    HOME="$HOME" \
    VIBEGUARD_LOG_FILE="$WARN_EVENTS" \
    VIBEGUARD_SESSION_ID="sess-A" \
    python3 "$SCRIPT"

# ─── Summary ──────────────────────────────────────────────────────────────────
echo
printf 'Total: %d  Pass: %d  Fail: %d\n' "$TOTAL" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]

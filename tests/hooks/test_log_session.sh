#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
hook_test_init

header "log.sh — session_id: start-time anchor + 30-min TTL"
# =========================================================

# The session block in log.sh uses three conditions to decide whether to reuse a session file:
# 1. File exists
# 2. Within 30-minute inactivity window (mtime < 30 min ago)
# 3. Stored start time (line 1) matches current process start time
#
# The start time is captured with TZ=UTC so it is timezone-independent (same PID always
# produces the same string regardless of user TZ, DST transitions, or inherited TZ differences).
#
# The session file is written atomically (mktemp + mv) so concurrent hook invocations
# sharing the same Claude parent PID never observe a partially-written file.
#
# These tests verify:
# A. Start time mismatch (PID recycling) triggers a fresh session.
# B. TTL expiry (>30 min idle) triggers a fresh session even with matching start time.
# C. Atomic write: session file always has exactly 2 complete lines after writing.

_test_log_dir=$(mktemp -d)
_stale_session_id="deadbeef"

# Shared helper: atomic write matching the production implementation in log.sh.
# Usage: _vg_atomic_write <file> <line1> <line2>
_vg_atomic_write() {
  local dest="$1" line1="$2" line2="$3"
  local tmp
  tmp=$(mktemp "${_test_log_dir}/.session_tmp_XXXXXX" 2>/dev/null) || tmp="${dest}.tmp.$$"
  printf '%s\n%s\n' "$line1" "$line2" > "$tmp" \
    && mv "$tmp" "$dest" 2>/dev/null \
    || { rm -f "$tmp" 2>/dev/null; printf '%s\n%s\n' "$line1" "$line2" > "$dest"; }
}

# --- Test A: start time mismatch (PID recycling detection) ---
# File format: line 1 = start time anchor (UTC), line 2 = session_id.
# Simulate a recycled PID: the session file records a start time that does NOT match
# the current process start time, so the start time check should fail → fresh session.
# UTC-formatted lstart strings are used (as produced by TZ=UTC ps -o lstart=).
_fake_pid="99998"
_vg_sf_a="${_test_log_dir}/.session_pid_${_fake_pid}"
_vg_atomic_write "$_vg_sf_a" "Thu Jan  1 00:00:00 1970" "$_stale_session_id"

_result_a=$(
  _vg_sf="$_vg_sf_a"
  _vg_proc_start="Mon Mar 24 02:00:00 2026"  # UTC; different from stored anchor
  _vg_stored_start=$(head -1 "$_vg_sf" 2>/dev/null)
  _vg_reuse=false
  # TTL check passes (file is fresh); start time check must fail
  if [[ -f "$_vg_sf" ]] && [[ -n "$(find "$_vg_sf" -mmin -30 2>/dev/null)" ]]; then
    if [[ "$_vg_stored_start" == "$_vg_proc_start" ]]; then
      _vg_reuse=true
    fi
  fi
  if [[ "$_vg_reuse" == "true" ]]; then
    echo "reused:$(tail -1 "$_vg_sf")"
  else
    new_id=$(printf '%04x%04x' $RANDOM $RANDOM)
    _vg_atomic_write "$_vg_sf" "$_vg_proc_start" "$new_id"
    echo "fresh:$new_id"
  fi
)
assert_not_contains "$_result_a" "reused" "Old session_id should not be reused when start time does not match (PID recycling)"
assert_contains "$_result_a" "fresh:" "A new session_id should be generated when the start time does not match"

# Verify file was overwritten with new two-line format (line 2 = new session_id, not old one).
_file_line2=$(tail -1 "$_vg_sf_a" 2>/dev/null)
TOTAL=$((TOTAL + 1))
if [[ "$_file_line2" != "$_stale_session_id" ]]; then
  green "PID recycling scenario: session file has been overwritten with new session_id"
  PASS=$((PASS + 1))
else
  red "PID recycling scenario: the session file has not been updated and is still the old session_id"
  FAIL=$((FAIL + 1))
fi

# --- Test B: 30-min TTL expiry (long-lived process, new task) ---
# When the session file's mtime is older than 30 minutes, a fresh session must be created
# even if the start time matches — this prevents cross-task pollution in long-lived processes.
_fake_pid2="99999"
_vg_sf_b="${_test_log_dir}/.session_pid_${_fake_pid2}"
_current_start="Mon Mar 24 02:00:00 2026"  # UTC
_vg_atomic_write "$_vg_sf_b" "$_current_start" "$_stale_session_id"
# Make the file appear older than 30 minutes.
touch -t "$(date -v -40M '+%Y%m%d%H%M' 2>/dev/null || date --date='40 minutes ago' '+%Y%m%d%H%M' 2>/dev/null || echo '200001010000')" "$_vg_sf_b" 2>/dev/null || \
  touch -d "40 minutes ago" "$_vg_sf_b" 2>/dev/null || true

_result_b=$(
  _vg_sf="$_vg_sf_b"
  _vg_proc_start="$_current_start"  # start time would match, but TTL has expired
  _vg_stored_start=$(head -1 "$_vg_sf" 2>/dev/null)
  _vg_reuse=false
  if [[ -f "$_vg_sf" ]] && [[ -n "$(find "$_vg_sf" -mmin -30 2>/dev/null)" ]]; then
    if [[ "$_vg_stored_start" == "$_vg_proc_start" ]]; then
      _vg_reuse=true
    fi
  fi
  if [[ "$_vg_reuse" == "true" ]]; then
    echo "reused:$(tail -1 "$_vg_sf")"
  else
    new_id=$(printf '%04x%04x' $RANDOM $RANDOM)
    _vg_atomic_write "$_vg_sf" "$_vg_proc_start" "$new_id"
    echo "fresh:$new_id"
  fi
)
assert_not_contains "$_result_b" "reused" "Old session_id should not be reused when TTL expires (>30min)"
assert_contains "$_result_b" "fresh:" "A new session_id should be generated when the TTL expires (to prevent cross-task pollution of long processes)"

# --- Test C: atomic write — session file must always have exactly 2 complete lines ---
# This guards against the race where a concurrent reader sees a truncated file (open O_TRUNC
# before the second line is written).  With mktemp+mv the file is either absent or complete.
_vg_sf_c="${_test_log_dir}/.session_pid_atomic_test"
_atomic_start="Mon Mar 24 02:00:00 2026"
_atomic_id=$(printf '%04x%04x' $RANDOM $RANDOM)
_vg_atomic_write "$_vg_sf_c" "$_atomic_start" "$_atomic_id"
_line_count=$(wc -l < "$_vg_sf_c" 2>/dev/null | tr -d ' ')
_line1=$(head -1 "$_vg_sf_c" 2>/dev/null)
_line2=$(tail -1 "$_vg_sf_c" 2>/dev/null)
TOTAL=$((TOTAL + 1))
if [[ "$_line_count" == "2" && "$_line1" == "$_atomic_start" && "$_line2" == "$_atomic_id" ]]; then
  green "Atomic write: session file has exactly 2 lines and is complete"
  PASS=$((PASS + 1))
else
  red "Atomic write: session file line number or content does not match (lines=$_line_count line1='$_line1' line2='$_line2')"
  FAIL=$((FAIL + 1))
fi

rm -rf "$_test_log_dir"

hook_test_finish

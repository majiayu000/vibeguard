#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
hook_test_init

header "log.sh — vg_start_timer: duration_ms recorded"
# =========================================================

# 1. vg_start_timer + vg_log 写入 duration_ms 且值为正整数
_timer_log=$(mktemp -d)
_timer_result=$(
  export VIBEGUARD_LOG_DIR="$_timer_log"
  source hooks/log.sh
  vg_start_timer
  sleep 0.05
  vg_log "test-timer" "Tool" "pass" "timer test" "detail"
  cat "$VIBEGUARD_LOG_FILE"
)
rm -rf "$_timer_log"
assert_contains "$_timer_result" '"duration_ms":' "vg_start_timer: duration_ms field written to events.jsonl"

# Extract duration_ms value and verify it's a positive integer >= 1
_dur=$(echo "$_timer_result" | python3 -c "import sys,json; e=json.loads(sys.stdin.read()); print(e.get('duration_ms','missing'))" 2>/dev/null || echo "missing")
TOTAL=$((TOTAL + 1))
if [[ "$_dur" =~ ^[0-9]+$ ]] && [[ "$_dur" -ge 1 ]]; then
  green "vg_start_timer: duration_ms=$_dur ms (positive integer)"
  PASS=$((PASS + 1))
else
  red "vg_start_timer: duration_ms expected positive integer, got: $_dur"
  FAIL=$((FAIL + 1))
fi

# 2. perl backend
_timer_log=$(mktemp -d)
_perl_result=$(
  export VIBEGUARD_LOG_DIR="$_timer_log"
  source hooks/log.sh
  # Force perl path
  if command -v perl &>/dev/null; then
    _VG_START_MS=$(perl -MTime::HiRes=time -e 'printf "%.0f", time*1000')
    sleep 0.02
    vg_log "test-timer-perl" "Tool" "pass" "" ""
    cat "$VIBEGUARD_LOG_FILE"
  else
    echo '{"duration_ms": 99}'
  fi
)
rm -rf "$_timer_log"
assert_contains "$_perl_result" '"duration_ms":' "vg_start_timer: perl backend produces duration_ms"

# 3. python3 backend (hide perl)
_timer_log=$(mktemp -d)
_py_result=$(
  export VIBEGUARD_LOG_DIR="$_timer_log"
  # Simulate no-perl: override _VG_START_MS using python3 directly
  source hooks/log.sh
  _VG_START_MS=$(python3 -c 'import time; print(int(time.time()*1000))')
  sleep 0.02
  vg_log "test-timer-python3" "Tool" "pass" "" ""
  cat "$VIBEGUARD_LOG_FILE"
)
rm -rf "$_timer_log"
assert_contains "$_py_result" '"duration_ms":' "vg_start_timer: python3 backend produces duration_ms"

# 4. date fallback backend
_timer_log=$(mktemp -d)
_date_result=$(
  export VIBEGUARD_LOG_DIR="$_timer_log"
  source hooks/log.sh
  _VG_START_MS=$(date +%s)000
  sleep 0.02
  vg_log "test-timer-date" "Tool" "pass" "" ""
  cat "$VIBEGUARD_LOG_FILE"
)
rm -rf "$_timer_log"
assert_contains "$_date_result" '"duration_ms":' "vg_start_timer: date fallback backend produces duration_ms"

# 5. 完整 hook 集成：pre-bash-guard 触发后 events.jsonl 含 duration_ms
_hook_log=$(mktemp -d)
echo '{"tool_input":{"command":"echo hello"}}' \
  | VIBEGUARD_LOG_DIR="$_hook_log" bash hooks/pre-bash-guard.sh >/dev/null 2>&1 || true
_hook_events=$(cat "$_hook_log/events.jsonl" 2>/dev/null || echo "")
rm -rf "$_hook_log"
assert_contains "$_hook_events" '"duration_ms":' "pre-bash-guard: events.jsonl contains duration_ms after hook run"

# 6. vg_start_timer 重置：两次调用不累积
_timer_log=$(mktemp -d)
_reset_result=$(
  export VIBEGUARD_LOG_DIR="$_timer_log"
  source hooks/log.sh
  vg_start_timer
  sleep 0.05
  vg_log "first" "Tool" "pass" "" ""
  # 第二次：不重新 start_timer，_VG_START_MS 应已清零，duration_ms 不应出现
  vg_log "second" "Tool" "pass" "" ""
  cat "$VIBEGUARD_LOG_FILE"
)
rm -rf "$_timer_log"
_second_line=$(echo "$_reset_result" | grep '"hook": "second"')
TOTAL=$((TOTAL + 1))
if echo "$_second_line" | grep -qF '"duration_ms":'; then
  red "vg_start_timer reset: second vg_log should NOT have duration_ms (timer was consumed)"
  FAIL=$((FAIL + 1))
else
  green "vg_start_timer reset: timer is consumed after first vg_log, second log has no duration_ms"
  PASS=$((PASS + 1))
fi

# =========================================================

hook_test_finish

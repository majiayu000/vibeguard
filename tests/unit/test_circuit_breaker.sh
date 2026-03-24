#!/usr/bin/env bash
# Unit tests for hooks/circuit-breaker.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CB_SCRIPT="${REPO_DIR}/hooks/circuit-breaker.sh"

PASS=0; FAIL=0; TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }

assert_ok() {
  local desc="$1"; shift; TOTAL=$((TOTAL+1))
  if "$@" >/dev/null 2>&1; then green "$desc"; PASS=$((PASS+1))
  else red "$desc (expected exit 0)"; FAIL=$((FAIL+1)); fi
}

assert_fail() {
  local desc="$1"; shift; TOTAL=$((TOTAL+1))
  if "$@" >/dev/null 2>&1; then red "$desc (expected non-zero)"; FAIL=$((FAIL+1))
  else green "$desc"; PASS=$((PASS+1)); fi
}

assert_output_contains() {
  local desc="$1" expected="$2"; shift 2; TOTAL=$((TOTAL+1))
  local out; out=$("$@" 2>&1 || true)
  if echo "$out" | grep -qF "$expected"; then green "$desc"; PASS=$((PASS+1))
  else red "$desc (missing: '$expected' in: '$out')"; FAIL=$((FAIL+1)); fi
}

assert_output_not_contains() {
  local desc="$1" unexpected="$2"; shift 2; TOTAL=$((TOTAL+1))
  local out; out=$("$@" 2>&1 || true)
  if echo "$out" | grep -qF "$unexpected"; then
    red "$desc (unexpected: '$unexpected')"; FAIL=$((FAIL+1))
  else green "$desc"; PASS=$((PASS+1)); fi
}

# ── Test helpers ──────────────────────────────────────────────────────────────

CB_TMPDIR=""

setup() {
  CB_TMPDIR="$(mktemp -d)"
  export VIBEGUARD_LOG_DIR="$CB_TMPDIR"
  export VIBEGUARD_SESSION_ID="testsession01"
  unset VG_CB_COOLDOWN VG_CB_THRESHOLD CI GITHUB_ACTIONS TRAVIS CIRCLECI JENKINS_URL GITLAB_CI TF_BUILD
}

teardown() {
  [[ -n "$CB_TMPDIR" ]] && rm -rf "$CB_TMPDIR"
}

# Run a snippet that sources circuit-breaker.sh in a subshell with isolated CB_DIR
run_cb() {
  bash -c "
    export VIBEGUARD_LOG_DIR='${CB_TMPDIR}'
    export VIBEGUARD_SESSION_ID='${VIBEGUARD_SESSION_ID:-testsession01}'
    ${VG_CB_EXTRA_ENV:-}
    source '${CB_SCRIPT}'
    $*
  " 2>&1
}

run_cb_exit() {
  bash -c "
    export VIBEGUARD_LOG_DIR='${CB_TMPDIR}'
    export VIBEGUARD_SESSION_ID='${VIBEGUARD_SESSION_ID:-testsession01}'
    ${VG_CB_EXTRA_ENV:-}
    source '${CB_SCRIPT}'
    $*
  " >/dev/null 2>&1
  echo $?
}

printf '\n=== circuit-breaker.sh ===\n'

# ── 1. CLOSED state: vg_cb_check returns 0 ───────────────────────────────────
printf '\n--- State machine ---\n'

setup
assert_ok "CLOSED: vg_cb_check passes on fresh state" \
  bash -c "
    export VIBEGUARD_LOG_DIR='${CB_TMPDIR}'
    export VIBEGUARD_SESSION_ID='testsession01'
    source '${CB_SCRIPT}'
    vg_cb_check 'test-hook'
  "
teardown

# ── 2. Trip circuit after CB_THRESHOLD blocks ────────────────────────────────
setup
TRIP_TEST=$(bash -c "
  export VIBEGUARD_LOG_DIR='${CB_TMPDIR}'
  export VIBEGUARD_SESSION_ID='testsession01'
  export VG_CB_THRESHOLD=3
  source '${CB_SCRIPT}'
  vg_cb_record_block 'test-hook'
  vg_cb_record_block 'test-hook'
  vg_cb_record_block 'test-hook'
  # Now circuit should be OPEN; vg_cb_check should return 1
  vg_cb_check 'test-hook' && echo 'PASSED_THROUGH' || echo 'AUTO_PASSED'
" 2>&1 || true)
TOTAL=$((TOTAL+1))
if echo "$TRIP_TEST" | grep -q "AUTO_PASSED"; then
  green "OPEN after 3 blocks: vg_cb_check returns 1 (auto-pass)"; PASS=$((PASS+1))
else
  red "OPEN after 3 blocks: expected AUTO_PASSED, got: $TRIP_TEST"; FAIL=$((FAIL+1))
fi
teardown

# ── 3. Below threshold: stays CLOSED ────────────────────────────────────────
setup
BELOW_TEST=$(bash -c "
  export VIBEGUARD_LOG_DIR='${CB_TMPDIR}'
  export VIBEGUARD_SESSION_ID='testsession01'
  export VG_CB_THRESHOLD=3
  source '${CB_SCRIPT}'
  vg_cb_record_block 'test-hook'
  vg_cb_record_block 'test-hook'
  # Only 2 blocks, threshold is 3 — still CLOSED
  vg_cb_check 'test-hook' && echo 'PASSED_THROUGH' || echo 'AUTO_PASSED'
" 2>&1 || true)
TOTAL=$((TOTAL+1))
if echo "$BELOW_TEST" | grep -q "PASSED_THROUGH"; then
  green "Below threshold: circuit stays CLOSED"; PASS=$((PASS+1))
else
  red "Below threshold: expected PASSED_THROUGH, got: $BELOW_TEST"; FAIL=$((FAIL+1))
fi
teardown

# ── 4. vg_cb_record_pass resets to CLOSED ───────────────────────────────────
setup
RESET_TEST=$(bash -c "
  export VIBEGUARD_LOG_DIR='${CB_TMPDIR}'
  export VIBEGUARD_SESSION_ID='testsession01'
  export VG_CB_THRESHOLD=2
  source '${CB_SCRIPT}'
  vg_cb_record_block 'test-hook'
  vg_cb_record_pass 'test-hook'   # reset
  vg_cb_record_block 'test-hook'  # should not trip (counter was reset)
  vg_cb_check 'test-hook' && echo 'PASSED_THROUGH' || echo 'AUTO_PASSED'
" 2>&1 || true)
TOTAL=$((TOTAL+1))
if echo "$RESET_TEST" | grep -q "PASSED_THROUGH"; then
  green "record_pass resets counter to CLOSED"; PASS=$((PASS+1))
else
  red "record_pass reset: expected PASSED_THROUGH, got: $RESET_TEST"; FAIL=$((FAIL+1))
fi
teardown

# ── 5. HALF-OPEN after cooldown ──────────────────────────────────────────────
setup
HALFOPEN_TEST=$(bash -c "
  export VIBEGUARD_LOG_DIR='${CB_TMPDIR}'
  export VIBEGUARD_SESSION_ID='testsession01'
  export VG_CB_THRESHOLD=2
  export VG_CB_COOLDOWN=0   # instant cooldown for testing
  source '${CB_SCRIPT}'
  vg_cb_record_block 'test-hook'
  vg_cb_record_block 'test-hook'  # trips to OPEN
  sleep 1                          # wait past cooldown (0s)
  vg_cb_check 'test-hook' && echo 'HALF_OPEN_PROBE' || echo 'STILL_OPEN'
" 2>&1 || true)
TOTAL=$((TOTAL+1))
if echo "$HALFOPEN_TEST" | grep -q "HALF_OPEN_PROBE"; then
  green "HALF-OPEN after cooldown expires: probe allowed"; PASS=$((PASS+1))
else
  red "HALF-OPEN probe: expected HALF_OPEN_PROBE, got: $HALFOPEN_TEST"; FAIL=$((FAIL+1))
fi
teardown

# ── 6. HALF-OPEN block → back to OPEN ───────────────────────────────────────
# Inject HALF-OPEN state directly to avoid cooldown=0 re-expiry race
setup
REOPEN_TEST=$(bash -c "
  export VIBEGUARD_LOG_DIR='${CB_TMPDIR}'
  export VIBEGUARD_SESSION_ID='testsession01'
  export VG_CB_THRESHOLD=2
  export VG_CB_COOLDOWN=9999
  source '${CB_SCRIPT}'
  # Directly write HALF-OPEN state (old timestamp, same session)
  mkdir -p '${CB_TMPDIR}/circuit-breaker'
  printf 'CB_STATE=HALF-OPEN\nCB_BLOCKS=2\nCB_LAST_BLOCK=1\nCB_SESSION=testsession01\n' \
    > '${CB_TMPDIR}/circuit-breaker/test-hook.cb'
  # Block during probe → circuit returns to OPEN
  vg_cb_record_block 'test-hook'
  # vg_cb_check: OPEN with long cooldown → auto-pass (return 1)
  vg_cb_check 'test-hook' && echo 'PASSED_THROUGH' || echo 'BACK_TO_OPEN'
" 2>&1 || true)
TOTAL=$((TOTAL+1))
if echo "$REOPEN_TEST" | grep -q "BACK_TO_OPEN"; then
  green "HALF-OPEN block: circuit returns to OPEN"; PASS=$((PASS+1))
else
  red "HALF-OPEN reopen: expected BACK_TO_OPEN, got: $REOPEN_TEST"; FAIL=$((FAIL+1))
fi
teardown

# ── 7. Session isolation: new session resets circuit ─────────────────────────
setup
SESSION_TEST=$(bash -c "
  export VIBEGUARD_LOG_DIR='${CB_TMPDIR}'
  export VG_CB_THRESHOLD=2
  export VG_CB_COOLDOWN=9999
  source '${CB_SCRIPT}'
  # Trip in session A
  export VIBEGUARD_SESSION_ID='sessionA'
  vg_cb_record_block 'test-hook'
  vg_cb_record_block 'test-hook'  # OPEN in session A
  # Switch to session B — should start CLOSED
  export VIBEGUARD_SESSION_ID='sessionB'
  vg_cb_check 'test-hook' && echo 'NEW_SESSION_FRESH' || echo 'STILL_OPEN'
" 2>&1 || true)
TOTAL=$((TOTAL+1))
if echo "$SESSION_TEST" | grep -q "NEW_SESSION_FRESH"; then
  green "Session isolation: new session starts with CLOSED circuit"; PASS=$((PASS+1))
else
  red "Session isolation: expected NEW_SESSION_FRESH, got: $SESSION_TEST"; FAIL=$((FAIL+1))
fi
teardown

# ── 8. CI guard: vg_is_ci detects common CI vars ────────────────────────────
printf '\n--- CI guard ---\n'

setup
assert_ok "vg_is_ci: detects CI=true" \
  bash -c "source '${CB_SCRIPT}'; CI=true vg_is_ci"
assert_ok "vg_is_ci: detects GITHUB_ACTIONS=true" \
  bash -c "source '${CB_SCRIPT}'; GITHUB_ACTIONS=true vg_is_ci"
assert_fail "vg_is_ci: returns 1 when no CI vars set" \
  bash -c "
    unset CI GITHUB_ACTIONS TRAVIS CIRCLECI JENKINS_URL GITLAB_CI TF_BUILD
    source '${CB_SCRIPT}'
    vg_is_ci
  "
teardown

# ── 9. stop_hook_active: parses JSON correctly ───────────────────────────────
printf '\n--- stop_hook_active ---\n'

setup
assert_ok "stop_hook_active: returns 0 when true" \
  bash -c "
    source '${CB_SCRIPT}'
    vg_stop_hook_active '{\"stop_hook_active\": true}'
  "
assert_fail "stop_hook_active: returns 1 when false" \
  bash -c "
    source '${CB_SCRIPT}'
    vg_stop_hook_active '{\"stop_hook_active\": false}'
  "
assert_fail "stop_hook_active: returns 1 when field absent" \
  bash -c "
    source '${CB_SCRIPT}'
    vg_stop_hook_active '{\"session_id\": \"abc\"}'
  "
assert_fail "stop_hook_active: returns 1 on empty string" \
  bash -c "
    source '${CB_SCRIPT}'
    vg_stop_hook_active ''
  "
assert_fail "stop_hook_active: returns 1 on invalid JSON" \
  bash -c "
    source '${CB_SCRIPT}'
    vg_stop_hook_active 'not-json'
  "
teardown

# ── 10. State directory is created automatically ─────────────────────────────
printf '\n--- State persistence ---\n'

setup
STATEDIR_TEST=$(bash -c "
  export VIBEGUARD_LOG_DIR='${CB_TMPDIR}'
  export VIBEGUARD_SESSION_ID='testsession01'
  source '${CB_SCRIPT}'
  vg_cb_record_block 'statedir-hook'
  ls '${CB_TMPDIR}/circuit-breaker/statedir-hook.cb' 2>/dev/null && echo 'FILE_EXISTS' || echo 'MISSING'
" 2>&1 || true)
TOTAL=$((TOTAL+1))
if echo "$STATEDIR_TEST" | grep -q "FILE_EXISTS"; then
  green "State file created after record_block"; PASS=$((PASS+1))
else
  red "State file: expected FILE_EXISTS, got: $STATEDIR_TEST"; FAIL=$((FAIL+1))
fi
teardown

# ── Summary ───────────────────────────────────────────────────────────────────
echo
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' "$TOTAL" "$PASS" "$FAIL"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0

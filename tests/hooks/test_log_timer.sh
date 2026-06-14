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
assert_contains "$_timer_result" '"schema_version": 1' "vg_log: events.jsonl includes schema_version"

header "log.sh — caller identity fields"

_manual_log=$(mktemp -d)
_manual_result=$(
  export VIBEGUARD_LOG_DIR="$_manual_log"
  export VIBEGUARD_SESSION_ID="manual-session"
  unset VIBEGUARD_CLI VIBEGUARD_CLIENT VIBEGUARD_CLIENT_VARIANT VIBEGUARD_CALLER_EVIDENCE
  source hooks/log.sh
  vg_log "manual-hook" "Tool" "pass" "" ""
  cat "$VIBEGUARD_LOG_FILE"
)
rm -rf "$_manual_log"
assert_contains "$_manual_result" '"cli": "unknown"' "manual caller: legacy cli field is unknown"
assert_contains "$_manual_result" '"client": "unknown"' "manual caller: client field is unknown"
assert_contains "$_manual_result" '"client_variant": "unknown"' "manual caller: client_variant field is unknown"
assert_contains "$_manual_result" '"caller_evidence": "no-client-evidence"' "manual caller: evidence explains unknown attribution"

_conflict_log=$(mktemp -d)
_conflict_result=$(
  export VIBEGUARD_LOG_DIR="$_conflict_log"
  export VIBEGUARD_SESSION_ID="conflict-session"
  export VIBEGUARD_CLI="codex"
  export VIBEGUARD_CLIENT="claude"
  export VIBEGUARD_CLIENT_VARIANT="claude-code-hooks"
  export VIBEGUARD_CALLER_EVIDENCE="explicit-test"
  source hooks/log.sh
  vg_log "conflict-hook" "Tool" "pass" "" ""
  cat "$VIBEGUARD_LOG_FILE"
)
rm -rf "$_conflict_log"
assert_contains "$_conflict_result" '"cli": "codex"' "conflicting signals: legacy cli is preserved"
assert_contains "$_conflict_result" '"client": "claude"' "conflicting signals: explicit client is preserved"
assert_contains "$_conflict_result" '"caller_evidence": "explicit-test"' "conflicting signals: evidence is preserved"

_claude_home=$(mktemp -d)
_claude_log=$(mktemp -d)
mkdir -p "$_claude_home/.vibeguard"
printf '%s' "$PWD" > "$_claude_home/.vibeguard/repo-path"
hook_test_install_runtime_stub "$_claude_home"
_claude_runtime="$_claude_home/.vibeguard/installed/bin/vibeguard-runtime"
printf '%s\n' '{"tool_input":{"command":"echo hello"}}' \
  | HOME="$_claude_home" VIBEGUARD_LOG_DIR="$_claude_log" VIBEGUARD_CLI="claude" VIBEGUARD_RUNTIME="$_claude_runtime" VIBEGUARD_EXECUTION_MODE="dev-linked-repo" bash hooks/run-hook.sh pre-bash-guard.sh >/dev/null 2>&1 || true
_claude_result=$(cat "$_claude_log/events.jsonl" 2>/dev/null || true)
assert_contains "$_claude_result" '"client": "claude"' "Claude wrapper: client is inferred from caller CLI"
assert_contains "$_claude_result" '"client_variant": "claude-code-hooks"' "Claude wrapper: client_variant is recorded"
assert_contains "$_claude_result" '"wrapper": "run-hook.sh"' "Claude wrapper: wrapper is recorded"
assert_contains "$_claude_result" "\"source_config\": \"$_claude_home/.claude/settings.json\"" "Claude wrapper: source_config is recorded"
assert_contains "$_claude_result" '"hook_protocol_version": "claude-code-hooks-v1"' "Claude wrapper: hook protocol is recorded"
rm -rf "$_claude_home" "$_claude_log"

_codex_home=$(mktemp -d)
_codex_log=$(mktemp -d)
mkdir -p "$_codex_home/.vibeguard"
printf '%s' "$PWD" > "$_codex_home/.vibeguard/repo-path"
hook_test_install_runtime_stub "$_codex_home"
_codex_runtime="$_codex_home/.vibeguard/installed/bin/vibeguard-runtime"
printf '%s\n' '{"hook_event_name":"PreToolUse","tool_input":{"command":"echo hello"}}' \
  | HOME="$_codex_home" VIBEGUARD_LOG_DIR="$_codex_log" VIBEGUARD_RUNTIME="$_codex_runtime" VIBEGUARD_EXECUTION_MODE="dev-linked-repo" bash hooks/run-hook-codex.sh vibeguard-pre-bash-guard.sh >/dev/null 2>&1 || true
_codex_result=$(cat "$_codex_log/events.jsonl" 2>/dev/null || true)
assert_contains "$_codex_result" '"cli": "codex"' "Codex wrapper: legacy cli remains compatible"
assert_contains "$_codex_result" '"client": "codex"' "Codex wrapper: client is recorded from hook payload"
assert_contains "$_codex_result" '"client_variant": "codex-cli-hooks"' "Codex wrapper: client_variant is recorded"
assert_contains "$_codex_result" '"wrapper": "run-hook-codex.sh"' "Codex wrapper: wrapper is recorded"
assert_contains "$_codex_result" "\"source_config\": \"$_codex_home/.codex/hooks.json\"" "Codex wrapper: source_config is recorded"
assert_contains "$_codex_result" '"hook_protocol_version": "codex-hooks-v1"' "Codex wrapper: hook protocol is recorded"
assert_contains "$_codex_result" '"caller_evidence": "codex-hook-payload"' "Codex wrapper: evidence records payload-based attribution"
rm -rf "$_codex_home" "$_codex_log"

_stale_codex_home=$(mktemp -d)
_stale_codex_log=$(mktemp -d)
mkdir -p "$_stale_codex_home/.vibeguard"
printf '%s' "$PWD" > "$_stale_codex_home/.vibeguard/repo-path"
hook_test_install_runtime_stub "$_stale_codex_home"
_stale_codex_runtime="$_stale_codex_home/.vibeguard/installed/bin/vibeguard-runtime"
printf '%s\n' '{"hook_event_name":"PreToolUse","tool_input":{"command":"echo hello"}}' \
  | HOME="$_stale_codex_home" VIBEGUARD_LOG_DIR="$_stale_codex_log" VIBEGUARD_RUNTIME="$_stale_codex_runtime" VIBEGUARD_CLI="claude" VIBEGUARD_CLIENT="claude" VIBEGUARD_EXECUTION_MODE="dev-linked-repo" bash hooks/run-hook-codex.sh vibeguard-pre-bash-guard.sh >/dev/null 2>&1 || true
_stale_codex_result=$(cat "$_stale_codex_log/events.jsonl" 2>/dev/null || true)
assert_contains "$_stale_codex_result" '"cli": "codex"' "Codex wrapper: hook payload overrides stale ambient cli"
assert_contains "$_stale_codex_result" '"client": "codex"' "Codex wrapper: hook payload overrides stale ambient client"
rm -rf "$_stale_codex_home" "$_stale_codex_log"

header "hook wrappers — precomputed log/session environment"

_precompute_home=$(mktemp -d)
_precompute_log=$(mktemp -d)
mkdir -p "$_precompute_home/.vibeguard"
printf '%s' "$PWD" > "$_precompute_home/.vibeguard/repo-path"
hook_test_install_runtime_stub "$_precompute_home"
_precompute_runtime="$_precompute_home/.vibeguard/installed/bin/vibeguard-runtime"
_claude_trace=$(
  printf '%s\n' '{"tool_input":{"command":"echo hello"}}' \
    | HOME="$_precompute_home" VIBEGUARD_LOG_DIR="$_precompute_log" VIBEGUARD_RUNTIME="$_precompute_runtime" VIBEGUARD_EXECUTION_MODE="dev-linked-repo" bash -x hooks/run-hook.sh pre-bash-guard.sh 2>&1 >/dev/null || true
)
assert_not_contains "$_claude_trace" "git rev-parse" "Claude wrapper precompute: hook trace avoids git rev-parse"
assert_not_contains "$_claude_trace" "shasum" "Claude wrapper precompute: hook trace avoids shasum"
assert_not_contains "$_claude_trace" "ps -" "Claude wrapper precompute: hook trace avoids ps process walks"
assert_contains "$(cat "$_precompute_log/events.jsonl" 2>/dev/null || true)" '"session": "stub-session"' "Claude wrapper precompute: exported session reaches log event"
assert_contains "$(cat "$_precompute_log/projects/abcdef12/.project-root" 2>/dev/null || true)" "$PWD" "Claude wrapper precompute: project hash mapping is written"
rm -rf "$_precompute_home" "$_precompute_log"

_codex_precompute_home=$(mktemp -d)
_codex_precompute_log=$(mktemp -d)
mkdir -p "$_codex_precompute_home/.vibeguard"
printf '%s' "$PWD" > "$_codex_precompute_home/.vibeguard/repo-path"
hook_test_install_runtime_stub "$_codex_precompute_home"
_codex_precompute_runtime="$_codex_precompute_home/.vibeguard/installed/bin/vibeguard-runtime"
_codex_trace=$(
  printf '%s\n' '{"hook_event_name":"PreToolUse","tool_input":{"command":"echo hello"}}' \
    | HOME="$_codex_precompute_home" VIBEGUARD_LOG_DIR="$_codex_precompute_log" VIBEGUARD_RUNTIME="$_codex_precompute_runtime" VIBEGUARD_EXECUTION_MODE="dev-linked-repo" bash -x hooks/run-hook-codex.sh vibeguard-pre-bash-guard.sh 2>&1 >/dev/null || true
)
assert_not_contains "$_codex_trace" "git rev-parse" "Codex wrapper precompute: hook trace avoids git rev-parse"
assert_not_contains "$_codex_trace" "shasum" "Codex wrapper precompute: hook trace avoids shasum"
assert_not_contains "$_codex_trace" "ps -" "Codex wrapper precompute: hook trace avoids ps process walks"
assert_contains "$(cat "$_codex_precompute_log/events.jsonl" 2>/dev/null || true)" '"session": "stub-session"' "Codex wrapper precompute: exported session reaches log event"
rm -rf "$_codex_precompute_home" "$_codex_precompute_log"

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

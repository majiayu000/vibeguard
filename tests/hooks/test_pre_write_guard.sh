#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
hook_test_init

header "pre-write-guard.sh — missing runtime fails closed"

runtime_missing_dir=$(mktemp -d)
mkdir -p "$runtime_missing_dir/home"
cp -R hooks "$runtime_missing_dir/hooks"
set +e
runtime_missing_stdout=$(printf '%s' '{"tool_input":{"file_path":"/project/conftest.py","content":"# bypass"}}' \
  | env -u VIBEGUARD_RUNTIME HOME="$runtime_missing_dir/home" bash "$runtime_missing_dir/hooks/pre-write-guard.sh" 2>"$runtime_missing_dir/stderr")
runtime_missing_rc=$?
set -e
runtime_missing_stderr="$(cat "$runtime_missing_dir/stderr")"
assert_contains "rc=$runtime_missing_rc" "rc=2" "missing runtime exits nonzero instead of silently passing"
assert_contains "$runtime_missing_stderr" "vibeguard-runtime not found" "missing runtime reports explicit install/build error"
assert_not_contains "$runtime_missing_stdout" '"decision": "pass"' "missing runtime does not emit a pass decision"
rm -rf "$runtime_missing_dir"
unset runtime_missing_dir runtime_missing_stdout runtime_missing_rc runtime_missing_stderr

header "pre-write-guard.sh — malformed input fails closed"

result=$(printf '%s' '{"tool_input":' | bash hooks/pre-write-guard.sh)
assert_contains "$result" '"decision": "block"' "Malformed Write hook JSON fails closed"
assert_contains "$result" "malformed PreToolUse(Write)" "Malformed Write hook input explains validation failure"
expected_malformed_output=$(cat <<'EOF'
{
  "decision": "block",
  "reason": "VIBEGUARD interception: malformed PreToolUse(Write) hook input. The write request could not be validated, so it was blocked instead of being treated as a safe skip."
}
EOF
)
assert_exit_zero "Malformed Write hook output matches legacy JSON shape" \
  bash -c '[[ "$1" == "$2" ]]' _ "$result" "$expected_malformed_output"

result=$(printf '%s' '{"tool_input":{}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" '"decision": "block"' "Write hook payload missing file_path fails closed"
assert_contains "$result" "malformed PreToolUse(Write)" "Missing Write file_path explains validation failure"

result=$(printf '%s' '{"tool_input":{"content":"fn main() {}"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" '"decision": "block"' "Write hook payload with content but no file_path fails closed"
assert_contains "$result" "malformed PreToolUse(Write)" "Missing Write file_path with content explains validation failure"

result=$(printf '%s' '{"tool_input":{"file_path":123,"content":"x"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" '"decision": "block"' "Write hook payload with non-string file_path fails closed"
assert_contains "$result" "malformed PreToolUse(Write)" "Non-string Write file_path explains validation failure"

result=$(printf '%s' '{"tool_input":{"file_path":"","content":"x"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" '"decision": "block"' "Write hook payload with empty file_path fails closed"
assert_contains "$result" "malformed PreToolUse(Write)" "Empty Write file_path explains validation failure"

header "pre-write-guard.sh — search first and then write"
# =========================================================

# Existing files should be released
result=$(echo '{"tool_input":{"file_path":"hooks/log.sh"}}' | bash hooks/pre-write-guard.sh)
assert_not_contains "$result" "VIBEGUARD" "Existing files are released directly"

# The new .md file should be released
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_nonexist_test_README.md"}}' | bash hooks/pre-write-guard.sh)
assert_not_contains "$result" "VIBEGUARD" "Create a new .md file and release it"

# The new .json file should be released
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_nonexist_test_config.json"}}' | bash hooks/pre-write-guard.sh)
assert_not_contains "$result" "VIBEGUARD" "Create a new .json file and release it"

#New test files should be released
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_nonexist_test_foo.test.ts"}}' | bash hooks/pre-write-guard.sh)
assert_not_contains "$result" "VIBEGUARD" "New test file released"

# New source code files should trigger reminder/interception
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_nonexist_test_service.py"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" "[L1]" "Create a new .py source code file to trigger guard"

result=$(echo '{"tool_input":{"file_path":"/tmp/vg_nonexist_test_main.rs"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" "[L1]" "Create a new .rs source file to trigger guard"

result=$(echo '{"tool_input":{"file_path":"/tmp/vg_nonexist_test_app.tsx"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" "[L1]" "Create a new .tsx source file to trigger guard"

# Source code files in the tests/ directory should be allowed
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_nonexist_test/tests/helper.py"}}' | bash hooks/pre-write-guard.sh)
assert_not_contains "$result" "VIBEGUARD" "Source code files in the tests/ directory are released"

# W-12: Writing to conftest.py should be intercepted (new file, correct basename)
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_nonexist_dir/conftest.py"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" '"decision": "block"' "W-12: Block writing to new conftest.py"
assert_contains "$result" "W-12" "W-12: write guard error message contains rule number"
expected_w12_output=$(cat <<'EOF'
{
  "decision": "block",
  "reason": "[W-12] [block] [this-edit] OBSERVATION: writing to test infrastructure file blocked (conftest.py/jest.config/pytest.ini/.coveragerc/babel.config)\nFIX: Fix the production code that is failing — do not manipulate test framework configuration"
}
EOF
)
assert_exit_zero "W-12 Write hook output matches legacy JSON shape" \
  bash -c '[[ "$1" == "$2" ]]' _ "$result" "$expected_w12_output"

# W-12: Writing to existing conftest.py paths (including directories) should also be blocked
result=$(echo '{"tool_input":{"file_path":"/project/tests/conftest.py"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" '"decision": "block"' "W-12: Intercept writing to existing conftest.py paths (including directories)"

# W-12: jest.config.ts writes should be intercepted
result=$(echo '{"tool_input":{"file_path":"/project/jest.config.ts"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" '"decision": "block"' "W-12: Block writing to jest.config.ts"

# W-12: writes to vitest.config.ts should be intercepted
result=$(echo '{"tool_input":{"file_path":"/project/vitest.config.ts"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" '"decision": "block"' "W-12: Block writes to vitest.config.ts"

# W-12: babel.config.js writes should be intercepted
result=$(echo '{"tool_input":{"file_path":"/project/babel.config.js"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" '"decision": "block"' "W-12: Block writes to babel.config.js"

# W-12: Normal config.json should not be intercepted by test infrastructure rules
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_nonexist_myconfig.json"}}' | bash hooks/pre-write-guard.sh)
assert_not_contains "$result" "W-12" "W-12: Normal config.json does not trigger test infrastructure protection"

# Circuit breaker: warn-mode advisories must silence after CB_THRESHOLD consecutive
# notices in the same session, so a 6-file batch write does not inject 6 redundant
# L1 advisories.
header "pre-write-guard.sh — circuit breaker silences batch advisories"

# Override VIBEGUARD_LOG_DIR for this block, but restore it afterwards because
# hook_test_lib registers a `trap EXIT 'rm -rf "$VIBEGUARD_LOG_DIR"'` that
# fails under set -u if the variable is unset on exit.
prev_log_dir="$VIBEGUARD_LOG_DIR"
cb_state_dir=$(mktemp -d)
export VIBEGUARD_LOG_DIR="$cb_state_dir"
export VG_CB_THRESHOLD=2
export VG_CB_COOLDOWN=300

result=$(echo '{"tool_input":{"file_path":"/tmp/vg_cb_test_1.go"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" "[L1]" "CB CLOSED: write #1 emits L1 advisory"

result=$(echo '{"tool_input":{"file_path":"/tmp/vg_cb_test_2.go"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" "[L1]" "CB CLOSED: write #2 emits L1 advisory (threshold reached)"

result=$(echo '{"tool_input":{"file_path":"/tmp/vg_cb_test_3.go"}}' | bash hooks/pre-write-guard.sh)
assert_not_contains "$result" "VIBEGUARD" "CB OPEN: write #3 is silent (no VIBEGUARD advisory)"
assert_not_contains "$result" "[L1]" "CB OPEN: write #3 has no L1 marker"

result=$(echo '{"tool_input":{"file_path":"/tmp/vg_cb_test_4.go"}}' | bash hooks/pre-write-guard.sh)
assert_not_contains "$result" "VIBEGUARD" "CB OPEN: write #4 also silent"

rm -rf "$cb_state_dir"
unset VG_CB_THRESHOLD VG_CB_COOLDOWN cb_state_dir

header "pre-write-guard.sh — circuit breaker errors fail closed"

cb_state_dir=$(mktemp -d)
export VIBEGUARD_LOG_DIR="$cb_state_dir"
export VIBEGUARD_SESSION_ID="prewrite-cb-error"
export VG_CB_LOCK_TIMEOUT_SECONDS=0
lock_file=$(bash -c 'source hooks/log.sh; source hooks/circuit-breaker.sh; _vg_cb_lock_file "pre-write-guard"')
mkdir -p "$(dirname "$lock_file")"

if command -v flock >/dev/null 2>&1; then
  ready_file="${cb_state_dir}/lock-ready"
  (
    exec 8>"$lock_file"
    flock -x 8
    : > "$ready_file"
    sleep 1
  ) &
  lock_holder=$!
  while [[ ! -f "$ready_file" ]]; do sleep 0.01; done
  result=$(echo '{"tool_input":{"file_path":"/tmp/vg_cb_error.go"}}' | bash hooks/pre-write-guard.sh 2>&1)
  wait "$lock_holder" 2>/dev/null || true
  unset lock_holder ready_file
else
  mkdir "${lock_file}.d"
  result=$(echo '{"tool_input":{"file_path":"/tmp/vg_cb_error.go"}}' | bash hooks/pre-write-guard.sh 2>&1)
  rmdir "${lock_file}.d"
fi

assert_contains "$result" '"decision": "block"' "CB lock error blocks instead of silently passing"
assert_contains "$result" "circuit breaker state" "CB lock error explains state failure"

rm -rf "$cb_state_dir"
export VIBEGUARD_LOG_DIR="$prev_log_dir"
unset VIBEGUARD_SESSION_ID VG_CB_LOCK_TIMEOUT_SECONDS cb_state_dir lock_file

# Escalation evidence must be based on advisories that were actually visible.
header "pre-write-guard.sh — silent circuit-breaker attempts do not escalate"

cb_state_dir=$(mktemp -d)
export VIBEGUARD_LOG_DIR="$cb_state_dir"
export VIBEGUARD_PROJECT_LOG_DIR="$cb_state_dir/project"
export VIBEGUARD_LOG_FILE="$VIBEGUARD_PROJECT_LOG_DIR/events.jsonl"
export VIBEGUARD_SESSION_ID="prewrite-silent-attempts"
export VG_CB_THRESHOLD=1
export VG_CB_COOLDOWN=300
export VIBEGUARD_PRE_WRITE_ESCALATE_THRESHOLD=3

result=$(echo '{"tool_input":{"file_path":"/tmp/vg_cb_silent_1.go"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" "[L1]" "silent attempts: write #1 emits the only visible reminder"

result=$(echo '{"tool_input":{"file_path":"/tmp/vg_cb_silent_2.go"}}' | bash hooks/pre-write-guard.sh)
assert_not_contains "$result" "VIBEGUARD" "silent attempts: write #2 is silenced by the open circuit"

result=$(echo '{"tool_input":{"file_path":"/tmp/vg_cb_silent_3.go"}}' | bash hooks/pre-write-guard.sh)
assert_not_contains "$result" "VIBEGUARD" "silent attempts: write #3 remains silent without escalating"

result=$(echo '{"tool_input":{"file_path":"/tmp/vg_cb_silent_4.go"}}' | bash hooks/pre-write-guard.sh)
assert_not_contains "$result" "VIBEGUARD" "silent attempts: write #4 remains silent without escalating"

silent_events=$(cat "$VIBEGUARD_LOG_FILE")
assert_occurrences "$silent_events" "New source file reminder" "1" "silent attempts: only one visible reminder is recorded"
assert_occurrences "$silent_events" "New source file attempt" "4" "silent attempts: attempt telemetry remains complete"
assert_not_contains "$silent_events" '"decision": "escalate"' "silent attempts: no escalation event is recorded"

rm -rf "$cb_state_dir"
unset cb_state_dir silent_events

# Only same-session Grep/Glob events form a recovery boundary. Invalid or
# unrelated history must not weaken escalation, and new reminders after a
# valid boundary must be able to escalate again.
header "pre-write-guard.sh — escalation recovers after same-session search"

cb_state_dir=$(mktemp -d)
export VIBEGUARD_LOG_DIR="$cb_state_dir"
export VIBEGUARD_PROJECT_LOG_DIR="$cb_state_dir/project"
export VIBEGUARD_LOG_FILE="$VIBEGUARD_PROJECT_LOG_DIR/events.jsonl"
export VIBEGUARD_SESSION_ID="prewrite-search-recovery"
export VG_CB_THRESHOLD=100

result=$(echo '{"tool_input":{"file_path":"/tmp/vg_search_1.go"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" "[L1]" "search recovery: reminder #1 is visible"
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_search_2.go"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" "[L1]" "search recovery: reminder #2 is visible"
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_search_3.go"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" "[L1]" "search recovery: reminder #3 is visible"

result=$(echo '{"tool_input":{"file_path":"/tmp/vg_search_blocked.go"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" '"decision": "block"' "search recovery: threshold still blocks unheeded visible reminders"
assert_contains "$result" "3 visible new source file reminders" "search recovery: block reports visible reminder count"
assert_contains "$result" "~/.vibeguard/config.json" "search recovery: threshold alternative names the persistent config path"
assert_contains "$result" "write_escalate_threshold" "search recovery: threshold alternative names the config key"
assert_contains "$result" "persistent global change" "search recovery: threshold alternative explains global persistence"
assert_not_contains "$result" "VIBEGUARD_PRE_WRITE_ESCALATE_THRESHOLD=0" "search recovery: block omits ineffective session-local export"

printf '%s\n' 'not-json' >> "$VIBEGUARD_LOG_FILE"
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_after_malformed.go"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" '"decision": "block"' "search recovery: malformed history does not reset escalation"

printf '%s\n' '{"session":"prewrite-search-recovery","hook":"other-hook","tool":"Grep","reason":"New source file reminder"}' >> "$VIBEGUARD_LOG_FILE"
printf '%s\n' '{"session":"prewrite-search-recovery","hook":"analysis-paralysis-guard","tool":"Edit","reason":"New source file reminder"}' >> "$VIBEGUARD_LOG_FILE"
printf '%s\n' '{"session":"prewrite-search-recovery","hook":"pre-write-guard","tool":"Write","reason":"unrelated"}' >> "$VIBEGUARD_LOG_FILE"
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_after_unrelated.go"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" '"decision": "block"' "search recovery: unrelated hook/tool/reason events do not reset escalation"

printf '%s\n' '{"session":"prewrite-search-recovery","hook":"analysis-paralysis-guard","tool":"Read"}' >> "$VIBEGUARD_LOG_FILE"
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_after_read.go"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" '"decision": "block"' "search recovery: same-session Read does not reset escalation"

printf '%s\n' '{"session":"other-session","hook":"analysis-paralysis-guard","tool":"Grep"}' >> "$VIBEGUARD_LOG_FILE"
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_after_other_session.go"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" '"decision": "block"' "search recovery: other-session Grep does not reset escalation"

printf '%s\n' '{"session":"prewrite-search-recovery","hook":"analysis-paralysis-guard","tool":"Grep"}' >> "$VIBEGUARD_LOG_FILE"
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_after_grep_1.go"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" "[L1]" "search recovery: same-session Grep releases the old escalation"
assert_not_contains "$result" '"decision": "block"' "search recovery: Grep retry is not trapped by old reminders"

result=$(echo '{"tool_input":{"file_path":"/tmp/vg_after_grep_2.go"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" "[L1]" "search recovery: post-Grep reminder #2 is visible"
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_after_grep_3.go"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" "[L1]" "search recovery: post-Grep reminder #3 is visible"
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_after_grep_blocked.go"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" '"decision": "block"' "search recovery: reminders after Grep can escalate again"

printf '%s\n' '{"session":"prewrite-search-recovery","hook":"analysis-paralysis-guard","tool":"Glob"}' >> "$VIBEGUARD_LOG_FILE"
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_after_glob.go"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" "[L1]" "search recovery: same-session Glob also releases escalation"
assert_not_contains "$result" '"decision": "block"' "search recovery: Glob retry is not trapped by old reminders"

export VIBEGUARD_PRE_WRITE_ESCALATE_THRESHOLD=0
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_escalation_disabled.go"}}' | bash hooks/pre-write-guard.sh)
assert_not_contains "$result" '"decision": "block"' "search recovery: threshold zero keeps escalation disabled"

rm -rf "$cb_state_dir"
unset VG_CB_THRESHOLD VG_CB_COOLDOWN VIBEGUARD_PRE_WRITE_ESCALATE_THRESHOLD
unset VIBEGUARD_PROJECT_LOG_DIR VIBEGUARD_LOG_FILE VIBEGUARD_SESSION_ID cb_state_dir result

# Codex P2 regression: a non-advisory write between source-file writes must
# reset the breaker so the threshold counts CONSECUTIVE advisories, not
# cumulative session-wide ones.
header "pre-write-guard.sh — non-advisory pass resets the breaker"

cb_state_dir=$(mktemp -d)
export VIBEGUARD_LOG_DIR="$cb_state_dir"
export VG_CB_THRESHOLD=2

result=$(echo '{"tool_input":{"file_path":"/tmp/vg_cb_reset_1.go"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" "[L1]" "reset: source #1 advises (count=1)"

result=$(echo '{"tool_input":{"file_path":"/tmp/vg_cb_reset_2.go"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" "[L1]" "reset: source #2 advises (count=2, threshold)"

# Non-advisory write — must reset the consecutive counter.
echo '{"tool_input":{"file_path":"/tmp/vg_cb_reset.md","content":"hi"}}' | bash hooks/pre-write-guard.sh >/dev/null

# After reset, the next source file should advise again instead of being silenced.
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_cb_reset_3.go"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" "[L1]" "reset: source #3 advises after .md pass (counter reset)"

rm -rf "$cb_state_dir"
export VIBEGUARD_LOG_DIR="$prev_log_dir"
unset VG_CB_THRESHOLD prev_log_dir cb_state_dir

# =========================================================

hook_test_finish

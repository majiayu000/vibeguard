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
  | HOME="$runtime_missing_dir/home" bash "$runtime_missing_dir/hooks/pre-write-guard.sh" 2>"$runtime_missing_dir/stderr")
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

# Escalation must count source-new attempts even when the circuit breaker is
# OPEN and individual reminder advisories are being silenced.
header "pre-write-guard.sh — escalation counts circuit-breaker auto-pass attempts"

cb_state_dir=$(mktemp -d)
export VIBEGUARD_LOG_DIR="$cb_state_dir"
export VG_CB_THRESHOLD=1
export VG_CB_COOLDOWN=300
export VIBEGUARD_PRE_WRITE_ESCALATE_THRESHOLD=3

result=$(echo '{"tool_input":{"file_path":"/tmp/vg_cb_escalate_1.go"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" "[L1]" "escalate: write #1 emits L1 advisory"

result=$(echo '{"tool_input":{"file_path":"/tmp/vg_cb_escalate_2.go"}}' | bash hooks/pre-write-guard.sh)
assert_not_contains "$result" "VIBEGUARD" "escalate: write #2 is silenced by open circuit"

result=$(echo '{"tool_input":{"file_path":"/tmp/vg_cb_escalate_3.go"}}' | bash hooks/pre-write-guard.sh)
assert_not_contains "$result" "VIBEGUARD" "escalate: write #3 is also silenced by open circuit"

result=$(echo '{"tool_input":{"file_path":"/tmp/vg_cb_escalate_4.go"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" '"decision": "block"' "escalate: write #4 blocks after counted source-new attempts"
assert_contains "$result" "3 new source file attempts" "escalate: block message reports counted attempts"

rm -rf "$cb_state_dir"
unset VG_CB_THRESHOLD VG_CB_COOLDOWN VIBEGUARD_PRE_WRITE_ESCALATE_THRESHOLD cb_state_dir

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

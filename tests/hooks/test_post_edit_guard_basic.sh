#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
hook_test_init

header "post-edit-guard.sh — quality warning"
# =========================================================

# Malformed PostToolUse input must be visible, not a silent SKIP
malformed_log_dir="$(mktemp -d)"
result=$(printf '%s' 'not-json' | VIBEGUARD_LOG_DIR="$malformed_log_dir" bash hooks/post-edit-guard.sh)
assert_contains "$result" "hookSpecificOutput" "Malformed PostToolUse(Edit) emits hook context"
assert_contains "$result" "malformed PostToolUse(Edit)" "Malformed PostToolUse(Edit) explains validation failure"
malformed_log_file="$(find "$malformed_log_dir" -name events.jsonl -print -quit)"
assert_contains "$(cat "$malformed_log_file" 2>/dev/null || true)" "Malformed hook input" "Malformed PostToolUse(Edit) writes hook log"
rm -rf "$malformed_log_dir"

# Valid non-file PostToolUse events remain silent
result=$(echo '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"echo ok"}}' | bash hooks/post-edit-guard.sh)
assert_not_contains "$result" "VIBEGUARD" "Non-file PostToolUse(Edit) event is silent"
assert_not_contains "$result" "hookSpecificOutput" "Non-file PostToolUse(Edit) event emits no hook context"

# Rust file added unwrap should warn
result=$(echo '{"tool_input":{"file_path":"src/main.rs","new_string":"let val = data.unwrap();"}}' | bash hooks/post-edit-guard.sh)
assert_contains "$result" "RS-03" "Detect Rust unwrap"

# Rust file adds unwrap_or_default which should not warn
result=$(echo '{"tool_input":{"file_path":"src/main.rs","new_string":"let val = data.unwrap_or_default();"}}' | bash hooks/post-edit-guard.sh)
assert_not_contains "$result" "RS-03" "Not false positive unwrap_or_default"

# unwrap in test files should not warn
result=$(echo '{"tool_input":{"file_path":"tests/test_main.rs","new_string":"let val = data.unwrap();"}}' | bash hooks/post-edit-guard.sh)
assert_not_contains "$result" "RS-03" "Test file unwrap does not warn"

# The new console.log in the TS file should warn (use absolute paths to avoid misjudgment of CLI projects)
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_test_app.ts","new_string":"console.log(data);"}}' | bash hooks/post-edit-guard.sh)
assert_contains "$result" "DEBUG" "Detect TS console.log"

# New print in Python file should warn
result=$(echo '{"tool_input":{"file_path":"src/main.py","new_string":"  print(data)"}}' | bash hooks/post-edit-guard.sh)
assert_contains "$result" "DEBUG" "Detect Python print()"

# Hardcoded .db paths should warn
result=$(echo '{"tool_input":{"file_path":"src/config.rs","new_string":"let db = \"app.db\";"}}' | bash hooks/post-edit-guard.sh)
assert_contains "$result" "U-11" "Detect hardcoded .db paths"

# =========================================================

hook_test_finish

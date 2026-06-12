#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
hook_test_init

header "post-edit-guard.sh — quality warning"
# =========================================================

result=$(printf 'not-json' | bash hooks/post-edit-guard.sh)
assert_contains "$result" "malformed PostToolUse(Edit)" "Malformed PostToolUse(Edit) input is visible"

# Rust file added unwrap should warn
result=$(echo '{"tool_input":{"file_path":"src/main.rs","new_string":"let val = data.unwrap();"}}' | bash hooks/post-edit-guard.sh)
assert_contains "$result" "RS-03" "Detect Rust unwrap"

# Rust file adds unwrap_or_default which should not warn
result=$(echo '{"tool_input":{"file_path":"src/main.rs","new_string":"let val = data.unwrap_or_default();"}}' | bash hooks/post-edit-guard.sh)
assert_not_contains "$result" "RS-03" "Not false positive unwrap_or_default"

# unwrap in test files should not warn
result=$(echo '{"tool_input":{"file_path":"tests/test_main.rs","new_string":"let val = data.unwrap();"}}' | bash hooks/post-edit-guard.sh)
assert_not_contains "$result" "RS-03" "Test file unwrap does not warn"

# Rust guard test-only filenames should match pre-commit guard classification
result=$(echo '{"tool_input":{"file_path":"src/tests.rs","new_string":"let val = data.expect(\"fixture\");"}}' | bash hooks/post-edit-guard.sh)
assert_not_contains "$result" "RS-03" "tests.rs expect does not warn"

result=$(echo '{"tool_input":{"file_path":"src/test_helpers.rs","new_string":"let db = \"fixture.db\";"}}' | bash hooks/post-edit-guard.sh)
assert_not_contains "$result" "U-11" "test_helpers.rs hardcoded db path does not warn"

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

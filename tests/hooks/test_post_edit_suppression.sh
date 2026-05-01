#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
hook_test_init

header "post-edit-guard — vibeguard-disable-next-line suppression"
# =========================================================

# RS-03 without suppression comment → should generate a warning
result=$(python3 -c "
import json
content = 'let x = foo.unwrap();'
print(json.dumps({'tool_input': {'file_path': 'src/main.rs', 'new_string': content}}))
" | VIBEGUARD_LOG_DIR="$VIBEGUARD_LOG_DIR" bash hooks/post-edit-guard.sh 2>/dev/null || true)
assert_contains "$result" "RS-03" "RS-03: unwrap() generates warning when unsuppressed annotation"

# RS-03 with suppress comment → warnings on this line should be suppressed
result=$(python3 -c "
import json
content = '// vibeguard-disable-next-line RS-03 -- signal handler\nlet x = foo.unwrap();'
print(json.dumps({'tool_input': {'file_path': 'src/main.rs', 'new_string': content}}))
" | VIBEGUARD_LOG_DIR="$VIBEGUARD_LOG_DIR" bash hooks/post-edit-guard.sh 2>/dev/null || true)
assert_not_contains "$result" "RS-03" "RS-03: vibeguard-disable-next-line suppresses unwrap() warning"

# RS-10 with suppress comment → should be suppressed
result=$(python3 -c "
import json
content = '// vibeguard-disable-next-line RS-10 -- intentional drop\nlet _ = sender.send(msg);'
print(json.dumps({'tool_input': {'file_path': 'src/main.rs', 'new_string': content}}))
" | VIBEGUARD_LOG_DIR="$VIBEGUARD_LOG_DIR" bash hooks/post-edit-guard.sh 2>/dev/null || true)
assert_not_contains "$result" "RS-10" "RS-10: vibeguard-disable-next-line suppress let _ = warning"

# DEBUG with suppress comment → console warnings should be suppressed
result=$(python3 -c "
import json
content = '// vibeguard-disable-next-line DEBUG -- intentional stderr\nconsole.log(\"debug info\");'
print(json.dumps({'tool_input': {'file_path': 'src/service.ts', 'new_string': content}}))
" | VIBEGUARD_LOG_DIR="$VIBEGUARD_LOG_DIR" bash hooks/post-edit-guard.sh 2>/dev/null || true)
assert_not_contains "$result" "DEBUG" "DEBUG: vibeguard-disable-next-line suppresses console.log warnings"

# U-11 with suppress comments → hardcoded path warnings should be suppressed
result=$(python3 -c "
import json
content = '// vibeguard-disable-next-line U-11 -- test fixture\nconst DB = \"test.db\";'
print(json.dumps({'tool_input': {'file_path': 'src/config.ts', 'new_string': content}}))
" | VIBEGUARD_LOG_DIR="$VIBEGUARD_LOG_DIR" bash hooks/post-edit-guard.sh 2>/dev/null || true)
assert_not_contains "$result" "U-11" "U-11: vibeguard-disable-next-line suppress hardcoded path warnings"

# Suppress comments only apply to the next line (unwrap on the third line should still alarm)
result=$(python3 -c "
import json
content = '// vibeguard-disable-next-line RS-03 -- ok\nlet a = safe.unwrap();\nlet b = other.unwrap();'
print(json.dumps({'tool_input': {'file_path': 'src/main.rs', 'new_string': content}}))
" | VIBEGUARD_LOG_DIR="$VIBEGUARD_LOG_DIR" bash hooks/post-edit-guard.sh 2>/dev/null || true)
assert_contains "$result" "RS-03" "RS-03: Suppressing comments only applies to the next line, and unwrap on the third line will still alarm"

# =========================================================

hook_test_finish

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
hook_test_init

header "pre-edit-guard.sh — anti-hallucination editing"
# =========================================================

# Files that do not exist should be intercepted
result=$(echo '{"tool_input":{"file_path":"/nonexistent/file.rs","old_string":"test"}}' | bash hooks/pre-edit-guard.sh)
assert_contains "$result" '"decision": "block"' "Block editing of non-existent files"

# Paths containing single quotes should be handled safely (without crashing)
result=$(echo '{"tool_input":{"file_path":"/tmp/file'\''with'\''quotes.rs","old_string":"test"}}' | bash hooks/pre-edit-guard.sh)
assert_contains "$result" '"decision": "block"' "Safe handling of paths containing single quotes"

result=$(python3 - <<'PY' | bash hooks/pre-edit-guard.sh
import json
print(json.dumps({"tool_input": {"file_path": "/tmp/does-not-exist-\"quoted\"-\\path.py", "old_string": "abc"}}))
PY
)
assert_contains "$result" '"decision": "block"' "Safe handling of paths containing double quotes and backslashes"
assert_exit_zero "pre-edit block output remains valid JSON for escaped paths" python3 -c 'import json, sys; json.loads(sys.argv[1])' "$result"

# Existing file + empty old_string should be released
result=$(echo '{"tool_input":{"file_path":"hooks/log.sh","old_string":""}}' | bash hooks/pre-edit-guard.sh)
assert_not_contains "$result" '"decision": "block"' "Existing file + empty old_string release"

# Codex apply_patch updates do not provide old_string; line_delta must still
# hard-block edits that would cross the U-16 limit.
u16_file="${VIBEGUARD_LOG_DIR}/u16_probe.ts"
python3 - <<'PY' "${u16_file}"
import sys
from pathlib import Path

Path(sys.argv[1]).write_text("".join(f"// line {i:03d}\n" for i in range(1, 801)), encoding="utf-8")
PY
result=$(python3 - <<'PY' "${u16_file}" | bash hooks/pre-edit-guard.sh
import json
import sys

print(json.dumps({
    "tool_input": {
        "file_path": sys.argv[1],
        "old_string": "",
        "new_string": "// line 801",
        "vibeguard_line_delta": 1,
    }
}))
PY
)
assert_contains "$result" '"decision": "block"' "U-16: Block Codex apply_patch edit over 800 lines"
assert_contains "$result" "U-16" "U-16: Codex apply_patch edit block cites rule"

# W-12: Test infrastructure files should be intercepted (conftest.py)
result=$(echo '{"tool_input":{"file_path":"/any/path/conftest.py","old_string":""}}' | bash hooks/pre-edit-guard.sh)
assert_contains "$result" '"decision": "block"' "W-12: Block editing conftest.py"
assert_contains "$result" "W-12" "W-12: Error message contains rule number"

# W-12: jest.config.ts should be intercepted
result=$(echo '{"tool_input":{"file_path":"/project/jest.config.ts","old_string":""}}' | bash hooks/pre-edit-guard.sh)
assert_contains "$result" '"decision": "block"' "W-12: Block editing jest.config.ts"

# W-12: jest.config.js should be intercepted
result=$(echo '{"tool_input":{"file_path":"/project/jest.config.js","old_string":""}}' | bash hooks/pre-edit-guard.sh)
assert_contains "$result" '"decision": "block"' "W-12: Block editing jest.config.js"

# W-12: pytest.ini should be intercepted
result=$(echo '{"tool_input":{"file_path":"/project/pytest.ini","old_string":""}}' | bash hooks/pre-edit-guard.sh)
assert_contains "$result" '"decision": "block"' "W-12: Block editing pytest.ini"

# W-12: .coveragerc should be intercepted
result=$(echo '{"tool_input":{"file_path":"/project/.coveragerc","old_string":""}}' | bash hooks/pre-edit-guard.sh)
assert_contains "$result" '"decision": "block"' "W-12: intercept editing .coveragerc"

# W-12: Ordinary source files should not be blocked by test infrastructure rules
result=$(echo '{"tool_input":{"file_path":"hooks/log.sh","old_string":""}}' | bash hooks/pre-edit-guard.sh)
assert_not_contains "$result" "W-12" "W-12: Ordinary files do not trigger test infrastructure protection"

# =========================================================

hook_test_finish

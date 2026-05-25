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

result=$(echo '{"tool_input":{"file_path":"hoks/pre-edit-guard.sh","old_string":"test"}}' | bash hooks/pre-edit-guard.sh)
assert_contains "$result" "Likely candidates" "Missing-file fast path includes candidate heading"
assert_contains "$result" "${REPO_DIR}/hooks/pre-edit-guard.sh" "Missing-file fast path suggests tracked candidate"

fallback_hook_dir=$(mktemp -d)
fake_git_dir=$(mktemp -d)
cp hooks/pre-edit-guard.sh hooks/log.sh "$fallback_hook_dir/"
cp -R hooks/_lib "$fallback_hook_dir/_lib"
cat > "$fallback_hook_dir/vibeguard-runtime" <<'SH'
#!/usr/bin/env bash
printf 'FALLBACK\n'
SH
chmod +x "$fallback_hook_dir/vibeguard-runtime"
real_git=$(command -v git)
cat > "$fake_git_dir/git" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == "rev-parse --show-toplevel" ]]; then
  pwd
  exit 0
fi
if [[ "$1" == "-C" && "$3" == "ls-files" ]]; then
  printf 'fatal: unable to read index\n' >&2
  exit 128
fi
exec "$REAL_GIT" "$@"
SH
chmod +x "$fake_git_dir/git"
result=$(REAL_GIT="$real_git" PATH="$fake_git_dir:$PATH" \
  echo '{"tool_input":{"file_path":"missing-pre-edit-guard.sh","old_string":"test"}}' \
  | REAL_GIT="$real_git" PATH="$fake_git_dir:$PATH" bash "$fallback_hook_dir/pre-edit-guard.sh")
assert_contains "$result" '"decision": "block"' "Missing-file fallback still emits block JSON when candidate lookup fails"
assert_contains "$result" "Could not search tracked files" "Missing-file fallback reports git ls-files lookup failure"
assert_exit_zero "fallback lookup failure block output remains valid JSON" python3 -c 'import json, sys; json.loads(sys.argv[1])' "$result"
rm -rf "$fallback_hook_dir" "$fake_git_dir"

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

result=$(printf '{"tool_input":' | bash hooks/pre-edit-guard.sh)
assert_contains "$result" '"decision": "block"' "Malformed hook input fails closed"
assert_contains "$result" "malformed PreToolUse(Edit)" "Malformed hook input explains validation failure"

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

tmp_home=$(mktemp -d)
tmp_file=$(mktemp)
printf 'x\n' > "$tmp_file"
result=$(printf '{"tool_input":{"file_path":"%s","old_string":""}}' "$tmp_file" \
  | env -u VIBEGUARD_LOG_DIR -u VIBEGUARD_PROJECT_LOG_DIR -u VIBEGUARD_LOG_FILE HOME="$tmp_home" bash hooks/pre-edit-guard.sh)
assert_not_contains "$result" '"decision": "block"' "Default log-dir fast path releases valid edits"
global_log_text="$(cat "$tmp_home/.vibeguard/events.jsonl" 2>/dev/null || true)"
assert_contains "$global_log_text" '"hook":"pre-edit-guard"' "Default log-dir Rust fast path writes global log"
rm -rf "$tmp_home" "$tmp_file"

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

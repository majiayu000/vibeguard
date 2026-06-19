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
real_git=$(command -v git)
pre_edit_runtime="${VIBEGUARD_RUNTIME:-${REPO_DIR}/vibeguard-runtime/target/debug/vibeguard-runtime}"
if [[ ! -x "$pre_edit_runtime" ]]; then
  pre_edit_runtime="${REPO_DIR}/vibeguard-runtime/target/release/vibeguard-runtime"
fi
if [[ ! -x "$pre_edit_runtime" ]]; then
  echo "test_pre_edit_guard.sh requires vibeguard-runtime; run cargo build --manifest-path vibeguard-runtime/Cargo.toml" >&2
  exit 2
fi
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
  | VIBEGUARD_RUNTIME="$pre_edit_runtime" \
    REAL_GIT="$real_git" PATH="$fake_git_dir:$PATH" bash "$fallback_hook_dir/pre-edit-guard.sh")
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

tmp_lock_dir=$(mktemp -d)
tmp_lock_file=$(mktemp)
locked_log="$tmp_lock_dir/events.jsonl"
printf 'safe\n' > "$tmp_lock_file"
mkdir "${locked_log}.lock.d"
result=$(printf '{"tool_input":{"file_path":"%s","old_string":""}}' "$tmp_lock_file" \
  | VIBEGUARD_PROJECT_LOG_DIR="$tmp_lock_dir" \
    VIBEGUARD_LOG_FILE="$locked_log" \
    VIBEGUARD_PROJECT_HASH="locktest1" \
    VIBEGUARD_SESSION_ID="pre-edit-lock-test" \
    VIBEGUARD_LOG_LOCK_ATTEMPTS=1 \
    VIBEGUARD_LOG_LOCK_SLEEP_SECONDS=0 \
    bash hooks/pre-edit-guard.sh 2>/dev/null)
assert_not_contains "$result" '"decision": "block"' "Log append failure after safe pre-edit validation does not block"
assert_contains "$result" "VG-INTERNAL-LOG-APPEND" "Log append failure reports internal error code"
assert_contains "$result" "failure_kind=lock" "Log append failure reports lock failure kind"
assert_contains "$result" "pre-edit-lock-test" "Log append failure reports session id"
assert_contains "$result" "$locked_log" "Log append failure reports log path"
assert_contains "$result" "rmdir" "Log append failure reports stale-lock recovery command"
rm -rf "$tmp_lock_dir" "$tmp_lock_file"

tmp_advisory_lock_dir=$(mktemp -d)
advisory_locked_log="$tmp_advisory_lock_dir/events.jsonl"
advisory_file="$tmp_advisory_lock_dir/advisory_probe.ts"
python3 - <<'PY' "$advisory_file"
import sys
from pathlib import Path

Path(sys.argv[1]).write_text("".join(f"// line {i:03d}\n" for i in range(1, 701)), encoding="utf-8")
PY
mkdir "${advisory_locked_log}.lock.d"
result=$(python3 - <<'PY' "$advisory_file" \
  | VIBEGUARD_PROJECT_LOG_DIR="$tmp_advisory_lock_dir" \
    VIBEGUARD_LOG_FILE="$advisory_locked_log" \
    VIBEGUARD_PROJECT_HASH="advisory01" \
    VIBEGUARD_SESSION_ID="pre-edit-advisory-lock-test" \
    VIBEGUARD_LOG_LOCK_ATTEMPTS=1 \
    VIBEGUARD_LOG_LOCK_SLEEP_SECONDS=0 \
    bash hooks/pre-edit-guard.sh 2>/dev/null
import json
import sys

print(json.dumps({
    "tool_input": {
        "file_path": sys.argv[1],
        "old_string": "",
        "new_string": "// line 701",
        "vibeguard_line_delta": 1,
    }
}))
PY
)
assert_not_contains "$result" '"decision": "block"' "U-16 advisory log append failure does not block"
assert_contains "$result" "U-16" "U-16 advisory survives log append failure"
assert_contains "$result" "VG-INTERNAL-LOG-APPEND" "U-16 advisory log append failure reports internal error code"
assert_contains "$result" "failure_kind=lock" "U-16 advisory log append failure reports lock failure kind"
rm -rf "$tmp_advisory_lock_dir"

tmp_global_lock_dir=$(mktemp -d)
tmp_global_project_dir="$tmp_global_lock_dir/project"
global_lock_file=$(mktemp)
mkdir -p "$tmp_global_project_dir"
printf 'safe\n' > "$global_lock_file"
mkdir "$tmp_global_lock_dir/events.jsonl.lock.d"
result=$(printf '{"tool_input":{"file_path":"%s","old_string":""}}' "$global_lock_file" \
  | VIBEGUARD_LOG_DIR="$tmp_global_lock_dir" \
    VIBEGUARD_PROJECT_LOG_DIR="$tmp_global_project_dir" \
    VIBEGUARD_LOG_FILE="$tmp_global_project_dir/events.jsonl" \
    VIBEGUARD_PROJECT_HASH="globallock1" \
    VIBEGUARD_SESSION_ID="pre-edit-global-lock-test" \
    VIBEGUARD_LOG_LOCK_ATTEMPTS=1 \
    VIBEGUARD_LOG_LOCK_SLEEP_SECONDS=0 \
    bash hooks/pre-edit-guard.sh 2>/dev/null)
assert_not_contains "$result" '"decision": "block"' "Global mirror append failure after safe pre-edit validation does not block"
assert_contains "$result" "VG-INTERNAL-LOG-APPEND" "Global mirror append failure reports internal error code"
assert_contains "$result" "$tmp_global_lock_dir/events.jsonl" "Global mirror append failure reports global log path"
assert_contains "$result" "$tmp_global_lock_dir/events.jsonl.lock.d" "Global mirror append failure reports global lock recovery path"
rm -rf "$tmp_global_lock_dir" "$global_lock_file"

tmp_policy_lock_dir=$(mktemp -d)
policy_locked_log="$tmp_policy_lock_dir/events.jsonl"
mkdir "${policy_locked_log}.lock.d"
result=$(printf '{"tool_input":{"file_path":"%s","old_string":"test"}}' "$tmp_policy_lock_dir/missing.rs" \
  | VIBEGUARD_PROJECT_LOG_DIR="$tmp_policy_lock_dir" \
    VIBEGUARD_LOG_FILE="$policy_locked_log" \
    VIBEGUARD_PROJECT_HASH="policy01" \
    VIBEGUARD_SESSION_ID="pre-edit-policy-lock-test" \
    VIBEGUARD_LOG_LOCK_ATTEMPTS=1 \
    VIBEGUARD_LOG_LOCK_SLEEP_SECONDS=0 \
    bash hooks/pre-edit-guard.sh 2>/dev/null)
assert_contains "$result" '"decision": "block"' "Policy block still blocks when event log append fails"
assert_contains "$result" "File does not exist" "Policy block keeps real reason when event log append fails"
assert_contains "$result" "VG-INTERNAL-LOG-APPEND" "Policy block reports internal log failure code"
assert_contains "$result" "failure_kind=lock" "Policy block reports lock failure kind"
assert_contains "$result" "pre-edit-policy-lock-test" "Policy block reports session id"
assert_contains "$result" "$policy_locked_log" "Policy block reports log path"
assert_contains "$result" "rmdir" "Policy block reports stale-lock recovery command"
assert_not_contains "$result" "runtime pre-edit-check failed" "Policy block is not replaced by generic runtime failure"
rm -rf "$tmp_policy_lock_dir"

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

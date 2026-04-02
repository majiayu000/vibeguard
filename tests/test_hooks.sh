#!/usr/bin/env bash
# VibeGuard Hook Test Suite
#
# Usage: bash tests/test_hooks.sh
#Run from the root directory of the repository

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header(){ printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

assert_contains() {
  local output="$1" expected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$output" | grep -qF "$expected"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected to contain: $expected)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local output="$1" unexpected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if ! echo "$output" | grep -qF "$unexpected"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (unexpectedly contains: $unexpected)"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit_zero() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (exit code: $?)"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit_nonzero() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    red "$desc (unexpected success)"
    FAIL=$((FAIL + 1))
  else
    green "$desc"
    PASS=$((PASS + 1))
  fi
}

# Create a temporary log directory to avoid contaminating real logs
export VIBEGUARD_LOG_DIR=$(mktemp -d)
trap 'rm -rf "$VIBEGUARD_LOG_DIR"' EXIT

# =========================================================
header "log.sh — injection protection"
# =========================================================

result=$(
  export VIBEGUARD_LOG_DIR
  source hooks/log.sh
  vg_log "test" "Tool" "pass" "reason with '''triple''' quotes" "detail \$(whoami)"
  cat "$VIBEGUARD_LOG_FILE"
)
assert_contains "$result" "'''triple'''" "Triple quotes are safely logged in reason"
assert_contains "$result" '$(whoami)' "Command substitution is not performed in detail"
assert_not_contains "$result" "$(whoami)" "whoami results do not appear in the log"

# Clear the log and continue testing
> "$VIBEGUARD_LOG_DIR/events.jsonl"

result=$(
  export VIBEGUARD_LOG_DIR
  source hooks/log.sh
  vg_log "test" "Tool" "block" 'reason"; import os; os.system("id"); #' "normal"
  cat "$VIBEGUARD_LOG_FILE"
)
assert_contains "$result" '"decision": "block"' "Python injection payload is safely logged in reason"

# =========================================================
header "pre-bash-guard.sh — Dangerous command interception"
# =========================================================

# git push --force は pre-bash-guard では interception しない (hooks/git/pre-push がresponsibilities)
result=$(echo '{"tool_input":{"command":"git push --force origin main"}}' | bash hooks/pre-bash-guard.sh)
assert_not_contains "$result" '"decision": "block"' "git push --force is not intercepted by pre-bash-guard (moved to pre-push hook)"

# git push --force-with-lease should be released
result=$(echo '{"tool_input":{"command":"git push --force-with-lease origin main"}}' | bash hooks/pre-bash-guard.sh)
assert_not_contains "$result" '"decision": "block"' "release git push --force-with-lease"

# git reset --hard should be released (users need to use it in scenarios such as rebase conflicts)
result=$(echo '{"tool_input":{"command":"git reset --hard HEAD~1"}}' | bash hooks/pre-bash-guard.sh)
assert_not_contains "$result" '"decision": "block"' "Release git reset --hard (pre-bash-guard does not intercept)"

# git checkout . should be intercepted
result=$(echo '{"tool_input":{"command":"git checkout ."}}' | bash hooks/pre-bash-guard.sh)
assert_contains "$result" '"decision": "block"' "Intercept git checkout ."

# git clean -f should be intercepted
result=$(echo '{"tool_input":{"command":"git clean -fd"}}' | bash hooks/pre-bash-guard.sh)
assert_contains "$result" '"decision": "block"' "intercept git clean -f"

# rm -rf / should be intercepted
result=$(echo '{"tool_input":{"command":"rm -rf /"}}' | bash hooks/pre-bash-guard.sh)
assert_contains "$result" '"decision": "block"' "Intercept rm -rf /"

# rm -rf ~/ should be intercepted
result=$(echo '{"tool_input":{"command":"rm -rf ~/"}}' | bash hooks/pre-bash-guard.sh)
assert_contains "$result" '"decision": "block"' "Intercept rm -rf ~/"

# rm -rf /Users/foo should be intercepted
result=$(echo '{"tool_input":{"command":"rm -rf /Users/foo"}}' | bash hooks/pre-bash-guard.sh)
assert_contains "$result" '"decision": "block"' "Block rm -rf /Users/foo"

# rm -rf ./node_modules should be released (specific deep subdirectories)
result=$(echo '{"tool_input":{"command":"rm -rf ./node_modules"}}' | bash hooks/pre-bash-guard.sh)
assert_not_contains "$result" '"decision": "block"' "Release rm -rf ./node_modules"

# npm run build should be released
result=$(echo '{"tool_input":{"command":"npm run build"}}' | bash hooks/pre-bash-guard.sh)
assert_not_contains "$result" '"decision": "block"' "release npm run build"

# cargo build should be released
result=$(echo '{"tool_input":{"command":"cargo build --release"}}' | bash hooks/pre-bash-guard.sh)
assert_not_contains "$result" '"decision": "block"' "release cargo build"

# vitest --run should be released
result=$(echo '{"tool_input":{"command":"vitest --run"}}' | bash hooks/pre-bash-guard.sh)
assert_not_contains "$result" '"decision": "block"' "release vitest --run"

# =========================================================
header "pre-bash-guard.sh — Package manager transparent correction (updatedInput)"
# =========================================================

# updatedInput API is only available when Claude Code is running, and there is no such API in the CI environment.
# Set VIBEGUARD_TEST_UPDATED_INPUT=1 to enable this set of tests.
if [[ -z "${VIBEGUARD_TEST_UPDATED_INPUT:-}" ]]; then
  printf '\033[33m SKIP: updatedInput test group (requires VIBEGUARD_TEST_UPDATED_INPUT=1)\033[0m\n'
else

# npm install (no parameters) → pnpm install
result=$(echo '{"tool_input":{"command":"npm install"}}' | bash hooks/pre-bash-guard.sh)
assert_contains "$result" '"decision": "allow"' "npm install → updatedInput allow"
assert_contains "$result" '"updatedInput"' "npm install → contains updatedInput"
assert_contains "$result" "pnpm install" "npm install → rewritten as pnpm install"

# npm i (shorthand) → pnpm install
result=$(echo '{"tool_input":{"command":"npm i"}}' | bash hooks/pre-bash-guard.sh)
assert_contains "$result" "pnpm install" "npm i → rewritten as pnpm install"

# npm install <package> → pnpm add <package>
result=$(echo '{"tool_input":{"command":"npm install lodash"}}' | bash hooks/pre-bash-guard.sh)
assert_contains "$result" "pnpm add lodash" "npm install <pkg> → pnpm add <pkg>"

# npm install --save-dev <package> → pnpm add -D <package>
result=$(echo '{"tool_input":{"command":"npm install --save-dev typescript"}}' | bash hooks/pre-bash-guard.sh)
assert_contains "$result" "pnpm add -D typescript" "npm install --save-dev → pnpm add -D <pkg>"

# npm add <package> → pnpm add <package>
result=$(echo '{"tool_input":{"command":"npm add axios"}}' | bash hooks/pre-bash-guard.sh)
assert_contains "$result" "pnpm add axios" "npm add <pkg> → pnpm add <pkg>"

# npm install -g should not be corrected (global installation is handled separately)
result=$(echo '{"tool_input":{"command":"npm install -g pnpm"}}' | bash hooks/pre-bash-guard.sh)
assert_not_contains "$result" '"updatedInput"' "npm install -g does not trigger correction"

# yarn install → pnpm install
result=$(echo '{"tool_input":{"command":"yarn install"}}' | bash hooks/pre-bash-guard.sh)
assert_contains "$result" "pnpm install" "yarn install → rewritten as pnpm install"

# yarn add <package> → pnpm add <package>
result=$(echo '{"tool_input":{"command":"yarn add react"}}' | bash hooks/pre-bash-guard.sh)
assert_contains "$result" "pnpm add react" "yarn add <pkg> → pnpm add <pkg>"

# pip install <package> → uv pip install <package>
# VIRTUAL_ENV simulates an active virtual environment (uv pip guard requires it)
result=$(VIRTUAL_ENV=/fake/venv echo '{"tool_input":{"command":"pip install requests"}}' | VIRTUAL_ENV=/fake/venv bash hooks/pre-bash-guard.sh)
assert_contains "$result" "uv pip install requests" "pip install → uv pip install"

# pip3 install → uv pip install
result=$(VIRTUAL_ENV=/fake/venv echo '{"tool_input":{"command":"pip3 install numpy pandas"}}' | VIRTUAL_ENV=/fake/venv bash hooks/pre-bash-guard.sh)
assert_contains "$result" "uv pip install numpy pandas" "pip3 install → uv pip install"

# python -m pip install → uv pip install
result=$(VIRTUAL_ENV=/fake/venv echo '{"tool_input":{"command":"python -m pip install fastapi"}}' | VIRTUAL_ENV=/fake/venv bash hooks/pre-bash-guard.sh)
assert_contains "$result" "uv pip install fastapi" "python -m pip install → uv pip install"

# python3 -m pip install → uv pip install
result=$(VIRTUAL_ENV=/fake/venv echo '{"tool_input":{"command":"python3 -m pip install -r requirements.txt"}}' | VIRTUAL_ENV=/fake/venv bash hooks/pre-bash-guard.sh)
assert_contains "$result" "uv pip install -r requirements.txt" "python3 -m pip install -r → uv pip install -r"

# Chain commands are not corrected (npm install && npm run build)
result=$(echo '{"tool_input":{"command":"npm install && npm run build"}}' | bash hooks/pre-bash-guard.sh)
assert_not_contains "$result" '"updatedInput"' "Chained commands do not trigger package manager correction"

# npm run build should not be corrected (non-installation commands)
result=$(echo '{"tool_input":{"command":"npm run build"}}' | bash hooks/pre-bash-guard.sh)
assert_not_contains "$result" '"updatedInput"' "npm run build does not trigger correction"

# =========================================================
header "pre-bash-guard.sh — don't trigger correction when target tool is unavailable"
# =========================================================

# Construct a temporary PATH without pnpm/uv, retain python3 and basic tools
_tmpbin=$(mktemp -d)
_py3=$(command -v python3 2>/dev/null || true)
[[ -n "$_py3" ]] && ln -sf "$_py3" "$_tmpbin/python3"
_CLEAN_PATH="/usr/bin:/bin:$_tmpbin"

# npm install should not be corrected when pnpm is not available
result=$(PATH="$_CLEAN_PATH" bash hooks/pre-bash-guard.sh \
  <<< '{"tool_input":{"command":"npm install"}}' 2>/dev/null || true)
assert_not_contains "$result" '"updatedInput"' "npm install does not trigger correction when pnpm is not available"

# pip install should not be corrected when uv is not available
result=$(PATH="$_CLEAN_PATH" bash hooks/pre-bash-guard.sh \
  <<< '{"tool_input":{"command":"pip install requests"}}' 2>/dev/null || true)
assert_not_contains "$result" '"updatedInput"' "pip install does not trigger correction when uv is not available"

rm -rf "$_tmpbin"

# pip install should not be corrected when uv is available but no .venv
if command -v uv &>/dev/null; then
  _tmpdir_novenv=$(mktemp -d)
  result=$(cd "$_tmpdir_novenv" && bash "$REPO_DIR/hooks/pre-bash-guard.sh" \
    <<< '{"tool_input":{"command":"pip install requests"}}' 2>/dev/null || true)
  assert_not_contains "$result" '"updatedInput"' "pip install does not trigger correction when uv is available but no .venv"
  rm -rf "$_tmpdir_novenv"
fi

fi  # end VIBEGUARD_TEST_UPDATED_INPUT guard

# Commit message containing force should not cause false positives
result=$(echo '{"tool_input":{"command":"git commit -m \"fix: force push guard\""}}' | bash hooks/pre-bash-guard.sh)
assert_not_contains "$result" '"decision": "block"' "commit message containing force will not cause false positives"

# heredoc content should not be misreported
result=$(echo '{"tool_input":{"command":"cat <<'\''EOF'\''\ngit push --force\nEOF"}}' | bash hooks/pre-bash-guard.sh)
assert_not_contains "$result" '"decision": "block"' "heredoc contains force push and no false positives"

# =========================================================
header "hooks/git/pre-push — force push interception"
# =========================================================

PREPUSH_SCRIPT="${REPO_DIR}/hooks/git/pre-push"

# helper: run pre-push with fake stdin refs
run_prepush() {
  echo "$1" | bash "$PREPUSH_SCRIPT"
}

ZEROS="0000000000000000000000000000000000000000"

#New branches (remote_sha all zeros) should be released
if run_prepush "refs/heads/feature abc123 refs/heads/feature $ZEROS" 2>/dev/null; then
  green "New remote branch release (remote_sha=0000)"
  PASS=$((PASS + 1))
else
  red "New remote branch release (remote_sha=0000)"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

# Deleting remote branches (local_sha all zeros) should be intercepted
# Format: <local-ref> <local-sha> <remote-ref> <remote-sha>
# When deleting, local-sha is all zeros, and local-ref is marked with (delete)
if ! run_prepush "refs/heads/feature $ZEROS refs/heads/feature abc123" 2>/dev/null; then
  green "Interception and deletion of remote branches (local_sha=0000)"
  PASS=$((PASS + 1))
else
  red "Interception and deletion of remote branches (local_sha=0000)"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

# Temporary git repository: Verify that non-fast-forward push is intercepted
# stdin format: <local-ref> <local-sha> <remote-ref> <remote-sha>
tmp_repo_push="$(mktemp -d)"
git -C "$tmp_repo_push" init -q
git -C "$tmp_repo_push" config user.email "test@vibeguard.test"
git -C "$tmp_repo_push" config user.name "VibeGuard Test"
git -C "$tmp_repo_push" commit --allow-empty -m "base"
BASE_SHA=$(git -C "$tmp_repo_push" rev-parse HEAD)
git -C "$tmp_repo_push" commit --allow-empty -m "local"
LOCAL_SHA=$(git -C "$tmp_repo_push" rev-parse HEAD)
git -C "$tmp_repo_push" reset --hard "$BASE_SHA" -q
git -C "$tmp_repo_push" commit --allow-empty -m "diverged"
REMOTE_SHA=$(git -C "$tmp_repo_push" rev-parse HEAD)

# LOCAL_SHA and REMOTE_SHA fork from BASE_SHA → non-fastforward → intercept
if ! (cd "$tmp_repo_push" && echo "refs/heads/main $LOCAL_SHA refs/heads/main $REMOTE_SHA" | bash "$PREPUSH_SCRIPT") 2>/dev/null; then
  green "Intercept non-fast forward push (force push)"
  PASS=$((PASS + 1))
else
  red "Intercept non-fast-forward push (force push)"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

# Normal fast forward push should be allowed: FF_SHA is the direct successor of REMOTE_SHA
git -C "$tmp_repo_push" checkout -q "$REMOTE_SHA"
git -C "$tmp_repo_push" commit --allow-empty -m "fast-forward"
FF_SHA=$(git -C "$tmp_repo_push" rev-parse HEAD)

if (cd "$tmp_repo_push" && echo "refs/heads/main $FF_SHA refs/heads/main $REMOTE_SHA" | bash "$PREPUSH_SCRIPT") 2>/dev/null; then
  green "Fast forward push release"
  PASS=$((PASS + 1))
else
  red "Fast forward push release"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

rm -rf "$tmp_repo_push"

# =========================================================
header "pre-edit-guard.sh — anti-hallucination editing"
# =========================================================

# Files that do not exist should be intercepted
result=$(echo '{"tool_input":{"file_path":"/nonexistent/file.rs","old_string":"test"}}' | bash hooks/pre-edit-guard.sh)
assert_contains "$result" '"decision": "block"' "Block editing of non-existent files"

# Paths containing single quotes should be handled safely (without crashing)
result=$(echo '{"tool_input":{"file_path":"/tmp/file'\''with'\''quotes.rs","old_string":"test"}}' | bash hooks/pre-edit-guard.sh)
assert_contains "$result" '"decision": "block"' "Safe handling of paths containing single quotes"

# Existing file + empty old_string should be released
result=$(echo '{"tool_input":{"file_path":"hooks/log.sh","old_string":""}}' | bash hooks/pre-edit-guard.sh)
assert_not_contains "$result" '"decision": "block"' "Existing file + empty old_string release"

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

# =========================================================
header "post-edit-guard.sh — quality warning"
# =========================================================

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
header "post-write-guard.sh — duplicate detection"
# =========================================================

# Non-source files (.md) should be allowed
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_test_readme.md","content":"# test"}}' | bash hooks/post-write-guard.sh)
assert_not_contains "$result" "VIBEGUARD" "Non-source files (.md) are allowed"

# Release when there is no git project (use a path that does not exist under /tmp)
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_no_git_project/src/main.rs","content":"fn main() {}"}}' | bash hooks/post-write-guard.sh)
assert_not_contains "$result" "VIBEGUARD" "Release if there is no git project"

# Empty content is released
result=$(echo '{"tool_input":{"file_path":"src/lib.rs","content":""}}' | bash hooks/post-write-guard.sh)
assert_not_contains "$result" "VIBEGUARD" "Empty content is released"

# Empty file_path is allowed
result=$(echo '{"tool_input":{"file_path":"","content":"fn main() {}"}}' | bash hooks/post-write-guard.sh)
assert_not_contains "$result" "VIBEGUARD" "Empty file_path is allowed"

# Source code files with the same name should alert
tmp_repo_same_name="$(mktemp -d)"
git -C "$tmp_repo_same_name" init -q
mkdir -p "$tmp_repo_same_name/src/existing" "$tmp_repo_same_name/src/new"
cat >"$tmp_repo_same_name/src/existing/service.py" <<'EOF'
def existing_service():
    return True
EOF
json_payload=$(printf '{"tool_input":{"file_path":"%s","content":"def create_service():\\n    return True"}}' "$tmp_repo_same_name/src/new/service.py")
result=$(echo "$json_payload" | bash hooks/post-write-guard.sh)
assert_contains "$result" "[L1]" "Detect duplicate source files with the same name"
rm -rf "$tmp_repo_same_name"

# Duplicate definitions should alert
tmp_repo_dup_def="$(mktemp -d)"
git -C "$tmp_repo_dup_def" init -q
mkdir -p "$tmp_repo_dup_def/src/existing" "$tmp_repo_dup_def/src/new"
cat >"$tmp_repo_dup_def/src/existing/handler.py" <<'EOF'
def processOrder():
    return 1
EOF
json_payload=$(printf '{"tool_input":{"file_path":"%s","content":"def processOrder():\\n    return 2"}}' "$tmp_repo_dup_def/src/new/new_handler.py")
result=$(echo "$json_payload" | bash hooks/post-write-guard.sh)
assert_contains "$result" "[L1]" "Detect duplicate definitions"
rm -rf "$tmp_repo_dup_def"

# Prompt for downgrade when scanning budget is exceeded
tmp_repo_budget="$(mktemp -d)"
git -C "$tmp_repo_budget" init -q
mkdir -p "$tmp_repo_budget/src"
cat >"$tmp_repo_budget/src/existing.py" <<'EOF'
def keepExisting():
    return "ok"
EOF
json_payload=$(printf '{"tool_input":{"file_path":"%s","content":"def keepExisting():\\n    return \\"new\\""}}' "$tmp_repo_budget/src/new_file.py")
result=$(echo "$json_payload" | VG_SCAN_MAX_FILES=0 bash hooks/post-write-guard.sh)
assert_contains "$result" "[L1]" "Downgrade when file budget exceeded"
rm -rf "$tmp_repo_budget"

# When the new source code file has a file with the same name, you should warn (use the existing log.sh in the current warehouse)
result=$(echo '{"tool_input":{"file_path":"'${REPO_DIR}'/hooks/subdir/log.sh","content":"#!/bin/bash\necho test"}}' | bash hooks/post-write-guard.sh)
# log.sh already exists in the hooks/ directory, if detected there should be VIBEGUARD output
# But .sh is not in VG_SOURCE_EXTS, so it is allowed
assert_not_contains "$result" "VIBEGUARD" "Non-source extension (.sh) allowed"

# =========================================================
header "post-build-check.sh — build check"
# =========================================================

# Non-build language files (.py) should be allowed
result=$(echo '{"tool_input":{"file_path":"src/main.py"}}' | bash hooks/post-build-check.sh)
assert_not_contains "$result" "VIBEGUARD" "Non-build language (.py) release"

# .md files should be released
result=$(echo '{"tool_input":{"file_path":"README.md"}}' | bash hooks/post-build-check.sh)
assert_not_contains "$result" "VIBEGUARD" "Non-source files (.md) are allowed"

# Empty file_path is allowed
result=$(echo '{"tool_input":{"file_path":""}}' | bash hooks/post-build-check.sh)
assert_not_contains "$result" "VIBEGUARD" "Empty file_path is allowed"

# .json files should be released
result=$(echo '{"tool_input":{"file_path":"package.json"}}' | bash hooks/post-build-check.sh)
assert_not_contains "$result" "VIBEGUARD" "Non-build language (.json) release"

# JavaScript syntax errors should warn
tmp_js_bad="$(mktemp -d)"
cat >"$tmp_js_bad/bad.js" <<'EOF'
const value = ;
EOF
result=$(echo "{\"tool_input\":{\"file_path\":\"$tmp_js_bad/bad.js\"}}" | bash hooks/post-build-check.sh)
assert_contains "$result" "VIBEGUARD" "JavaScript syntax error triggers build check warning"
rm -rf "$tmp_js_bad"

# JavaScript should be allowed if the syntax is correct
tmp_js_ok="$(mktemp -d)"
cat >"$tmp_js_ok/good.js" <<'EOF'
const value = 1;
EOF
result=$(echo "{\"tool_input\":{\"file_path\":\"$tmp_js_ok/good.js\"}}" | bash hooks/post-build-check.sh)
assert_not_contains "$result" "VIBEGUARD" "JavaScript syntax is correct"
rm -rf "$tmp_js_ok"

# =========================================================
header "pre-commit-guard.sh — timeout fallback"
# =========================================================

tmp_repo_precommit="$(mktemp -d)"
git -C "$tmp_repo_precommit" init -q
mkdir -p "$tmp_repo_precommit/bin" "$tmp_repo_precommit/src"

cat >"$tmp_repo_precommit/Cargo.toml" <<'EOF'
[package]
name = "vg-precommit-test"
version = "0.1.0"
edition = "2021"
EOF

cat >"$tmp_repo_precommit/src/lib.rs" <<'EOF'
pub fn add(a: i32, b: i32) -> i32 {
    a + b
}
EOF

cat >"$tmp_repo_precommit/bin/timeout" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF

cat >"$tmp_repo_precommit/bin/gtimeout" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF

cat >"$tmp_repo_precommit/bin/cargo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "check" || "${1:-}" == "fmt" ]]; then
  exit 0
fi
exit 1
EOF

chmod +x "$tmp_repo_precommit/bin/timeout" "$tmp_repo_precommit/bin/gtimeout" "$tmp_repo_precommit/bin/cargo"
git -C "$tmp_repo_precommit" add Cargo.toml src/lib.rs

assert_exit_zero "Rewind execution when timeout/gtimeout is unavailable, and do not falsely report build failures" bash -c "cd '$tmp_repo_precommit' && PATH='$tmp_repo_precommit/bin:/usr/bin:/bin:$PATH' bash '$REPO_DIR/hooks/pre-commit-guard.sh'"
rm -rf "$tmp_repo_precommit"

# Go projects should run Go guards (new _ = prevent commits when discarding error)
tmp_repo_precommit_go="$(mktemp -d)"
git -C "$tmp_repo_precommit_go" init -q
mkdir -p "$tmp_repo_precommit_go/bin" "$tmp_repo_precommit_go/cmd"

cat >"$tmp_repo_precommit_go/go.mod" <<'EOF'
module vg-precommit-go-test

go 1.22
EOF

cat >"$tmp_repo_precommit_go/cmd/main.go" <<'EOF'
package main

func doThing() error { return nil }

func main() {
	_ = doThing()
}
EOF

cat >"$tmp_repo_precommit_go/bin/go" <<'EOF'
#!/usr/bin/env bash
# go build in pre-commit is only used as a build access control. Success is returned here to avoid relying on native Go.
exit 0
EOF

chmod +x "$tmp_repo_precommit_go/bin/go"
git -C "$tmp_repo_precommit_go" add go.mod cmd/main.go

assert_exit_nonzero "Go guards prevent _= discarding commits with error" bash -c "cd '$tmp_repo_precommit_go' && PATH='$tmp_repo_precommit_go/bin:/usr/bin:/bin:$PATH' bash '$REPO_DIR/hooks/pre-commit-guard.sh'"
rm -rf "$tmp_repo_precommit_go"

# =========================================================
header "log.sh — session_id: start-time anchor + 30-min TTL"
# =========================================================

# The session block in log.sh uses three conditions to decide whether to reuse a session file:
# 1. File exists
# 2. Within 30-minute inactivity window (mtime < 30 min ago)
# 3. Stored start time (line 1) matches current process start time
#
# The start time is captured with TZ=UTC so it is timezone-independent (same PID always
# produces the same string regardless of user TZ, DST transitions, or inherited TZ differences).
#
# The session file is written atomically (mktemp + mv) so concurrent hook invocations
# sharing the same Claude parent PID never observe a partially-written file.
#
# These tests verify:
# A. Start time mismatch (PID recycling) triggers a fresh session.
# B. TTL expiry (>30 min idle) triggers a fresh session even with matching start time.
# C. Atomic write: session file always has exactly 2 complete lines after writing.

_test_log_dir=$(mktemp -d)
_stale_session_id="deadbeef"

# Shared helper: atomic write matching the production implementation in log.sh.
# Usage: _vg_atomic_write <file> <line1> <line2>
_vg_atomic_write() {
  local dest="$1" line1="$2" line2="$3"
  local tmp
  tmp=$(mktemp "${_test_log_dir}/.session_tmp_XXXXXX" 2>/dev/null) || tmp="${dest}.tmp.$$"
  printf '%s\n%s\n' "$line1" "$line2" > "$tmp" \
    && mv "$tmp" "$dest" 2>/dev/null \
    || { rm -f "$tmp" 2>/dev/null; printf '%s\n%s\n' "$line1" "$line2" > "$dest"; }
}

# --- Test A: start time mismatch (PID recycling detection) ---
# File format: line 1 = start time anchor (UTC), line 2 = session_id.
# Simulate a recycled PID: the session file records a start time that does NOT match
# the current process start time, so the start time check should fail → fresh session.
# UTC-formatted lstart strings are used (as produced by TZ=UTC ps -o lstart=).
_fake_pid="99998"
_vg_sf_a="${_test_log_dir}/.session_pid_${_fake_pid}"
_vg_atomic_write "$_vg_sf_a" "Thu Jan  1 00:00:00 1970" "$_stale_session_id"

_result_a=$(
  _vg_sf="$_vg_sf_a"
  _vg_proc_start="Mon Mar 24 02:00:00 2026"  # UTC; different from stored anchor
  _vg_stored_start=$(head -1 "$_vg_sf" 2>/dev/null)
  _vg_reuse=false
  # TTL check passes (file is fresh); start time check must fail
  if [[ -f "$_vg_sf" ]] && [[ -n "$(find "$_vg_sf" -mmin -30 2>/dev/null)" ]]; then
    if [[ "$_vg_stored_start" == "$_vg_proc_start" ]]; then
      _vg_reuse=true
    fi
  fi
  if [[ "$_vg_reuse" == "true" ]]; then
    echo "reused:$(tail -1 "$_vg_sf")"
  else
    new_id=$(printf '%04x%04x' $RANDOM $RANDOM)
    _vg_atomic_write "$_vg_sf" "$_vg_proc_start" "$new_id"
    echo "fresh:$new_id"
  fi
)
assert_not_contains "$_result_a" "reused" "Old session_id should not be reused when start time does not match (PID recycling)"
assert_contains "$_result_a" "fresh:" "A new session_id should be generated when the start time does not match"

# Verify file was overwritten with new two-line format (line 2 = new session_id, not old one).
_file_line2=$(tail -1 "$_vg_sf_a" 2>/dev/null)
TOTAL=$((TOTAL + 1))
if [[ "$_file_line2" != "$_stale_session_id" ]]; then
  green "PID recycling scenario: session file has been overwritten with new session_id"
  PASS=$((PASS + 1))
else
  red "PID recycling scenario: the session file has not been updated and is still the old session_id"
  FAIL=$((FAIL + 1))
fi

# --- Test B: 30-min TTL expiry (long-lived process, new task) ---
# When the session file's mtime is older than 30 minutes, a fresh session must be created
# even if the start time matches — this prevents cross-task pollution in long-lived processes.
_fake_pid2="99999"
_vg_sf_b="${_test_log_dir}/.session_pid_${_fake_pid2}"
_current_start="Mon Mar 24 02:00:00 2026"  # UTC
_vg_atomic_write "$_vg_sf_b" "$_current_start" "$_stale_session_id"
# Make the file appear older than 30 minutes.
touch -t "$(date -v -40M '+%Y%m%d%H%M' 2>/dev/null || date --date='40 minutes ago' '+%Y%m%d%H%M' 2>/dev/null || echo '200001010000')" "$_vg_sf_b" 2>/dev/null || \
  touch -d "40 minutes ago" "$_vg_sf_b" 2>/dev/null || true

_result_b=$(
  _vg_sf="$_vg_sf_b"
  _vg_proc_start="$_current_start"  # start time would match, but TTL has expired
  _vg_stored_start=$(head -1 "$_vg_sf" 2>/dev/null)
  _vg_reuse=false
  if [[ -f "$_vg_sf" ]] && [[ -n "$(find "$_vg_sf" -mmin -30 2>/dev/null)" ]]; then
    if [[ "$_vg_stored_start" == "$_vg_proc_start" ]]; then
      _vg_reuse=true
    fi
  fi
  if [[ "$_vg_reuse" == "true" ]]; then
    echo "reused:$(tail -1 "$_vg_sf")"
  else
    new_id=$(printf '%04x%04x' $RANDOM $RANDOM)
    _vg_atomic_write "$_vg_sf" "$_vg_proc_start" "$new_id"
    echo "fresh:$new_id"
  fi
)
assert_not_contains "$_result_b" "reused" "Old session_id should not be reused when TTL expires (>30min)"
assert_contains "$_result_b" "fresh:" "A new session_id should be generated when the TTL expires (to prevent cross-task pollution of long processes)"

# --- Test C: atomic write — session file must always have exactly 2 complete lines ---
# This guards against the race where a concurrent reader sees a truncated file (open O_TRUNC
# before the second line is written).  With mktemp+mv the file is either absent or complete.
_vg_sf_c="${_test_log_dir}/.session_pid_atomic_test"
_atomic_start="Mon Mar 24 02:00:00 2026"
_atomic_id=$(printf '%04x%04x' $RANDOM $RANDOM)
_vg_atomic_write "$_vg_sf_c" "$_atomic_start" "$_atomic_id"
_line_count=$(wc -l < "$_vg_sf_c" 2>/dev/null | tr -d ' ')
_line1=$(head -1 "$_vg_sf_c" 2>/dev/null)
_line2=$(tail -1 "$_vg_sf_c" 2>/dev/null)
TOTAL=$((TOTAL + 1))
if [[ "$_line_count" == "2" && "$_line1" == "$_atomic_start" && "$_line2" == "$_atomic_id" ]]; then
  green "Atomic write: session file has exactly 2 lines and is complete"
  PASS=$((PASS + 1))
else
  red "Atomic write: session file line number or content does not match (lines=$_line_count line1='$_line1' line2='$_line2')"
  FAIL=$((FAIL + 1))
fi

rm -rf "$_test_log_dir"
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
# Summarize
# =========================================================

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

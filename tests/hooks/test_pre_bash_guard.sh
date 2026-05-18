#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
hook_test_init

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
assert_contains "$result" "authorized-discard.py" "git checkout . block points to authorized discard workflow"

# git checkout "." (quoted dot) should be intercepted
result=$(echo '{"tool_input":{"command":"git checkout \".\"" }}' | bash hooks/pre-bash-guard.sh)
assert_contains "$result" '"decision": "block"' "Intercept git checkout \".\" (quoted dot)"

# git restore "." (quoted dot) should be intercepted
result=$(echo '{"tool_input":{"command":"git restore \".\"" }}' | bash hooks/pre-bash-guard.sh)
assert_contains "$result" '"decision": "block"' "Intercept git restore \".\" (quoted dot)"

# git checkout '.' (single-quoted dot) should be intercepted
result=$(echo "{\"tool_input\":{\"command\":\"git checkout '.'\" }}" | bash hooks/pre-bash-guard.sh)
assert_contains "$result" '"decision": "block"' "Intercept git checkout '.' (single-quoted dot)"

# git restore '.' (single-quoted dot) should be intercepted
result=$(echo "{\"tool_input\":{\"command\":\"git restore '.'\" }}" | bash hooks/pre-bash-guard.sh)
assert_contains "$result" '"decision": "block"' "Intercept git restore '.' (single-quoted dot)"

# echo "git checkout ." should NOT be intercepted (false-positive guard)
result=$(echo '{"tool_input":{"command":"echo \"git checkout .\"" }}' | bash hooks/pre-bash-guard.sh)
assert_not_contains "$result" '"decision": "block"' "echo containing git checkout . not blocked"

# printf mentioning git restore . should NOT be intercepted (false-positive guard)
result=$(printf '%s' '{"tool_input":{"command":"printf \"%s\\n\" \"git restore .\"" }}' | bash hooks/pre-bash-guard.sh)
assert_not_contains "$result" '"decision": "block"' "printf containing git restore . not blocked"

# commit message mentioning git checkout . should NOT be intercepted (false-positive guard)
result=$(echo '{"tool_input":{"command":"git commit -m \"repro: git checkout .\"" }}' | bash hooks/pre-bash-guard.sh)
assert_not_contains "$result" '"decision": "block"' "commit message mentioning git checkout . not blocked"

# shell wrapper bypasses: env-var prefix, env command, command builtin, pipe — all should block
result=$(echo '{"tool_input":{"command":"GIT_TRACE=1 git checkout \".\"" }}' | bash hooks/pre-bash-guard.sh)
assert_contains "$result" '"decision": "block"' "GIT_TRACE=1 git checkout \".\" (env-var wrapper) intercepted"

result=$(echo '{"tool_input":{"command":"env GIT_TRACE=1 git restore \".\"" }}' | bash hooks/pre-bash-guard.sh)
assert_contains "$result" '"decision": "block"' "env GIT_TRACE=1 git restore \".\" (env command wrapper) intercepted"

result=$(echo '{"tool_input":{"command":"command git checkout \".\"" }}' | bash hooks/pre-bash-guard.sh)
assert_contains "$result" '"decision": "block"' "command git checkout \".\" (command builtin wrapper) intercepted"

result=$(echo '{"tool_input":{"command":"echo y | git checkout \".\"" }}' | bash hooks/pre-bash-guard.sh)
assert_contains "$result" '"decision": "block"' "echo y | git checkout \".\" (pipe wrapper) intercepted"

# separator false-positives from quoted strings — must NOT block
result=$(echo '{"tool_input":{"command":"git commit -m \"docs; git checkout .\"" }}' | bash hooks/pre-bash-guard.sh)
assert_not_contains "$result" '"decision": "block"' "commit message with semicolon before checkout mention not blocked"

result=$(echo '{"tool_input":{"command":"echo \"note && git restore .\"" }}' | bash hooks/pre-bash-guard.sh)
assert_not_contains "$result" '"decision": "block"' "echo string with && before restore mention not blocked"

result=$(echo '{"tool_input":{"command":"printf x > notes.md"}}' | bash hooks/pre-bash-guard.sh)
assert_contains "$result" '"hookSpecificOutput"' "non-standard markdown write emits schema-valid advisory context"
assert_contains "$result" '"hookEventName": "PreToolUse"' "non-standard markdown advisory targets PreToolUse"
assert_not_contains "$result" '"decision": "warn"' "non-standard markdown advisory does not emit invalid warn decision"

# git clean -f should be intercepted
result=$(echo '{"tool_input":{"command":"git clean -fd"}}' | bash hooks/pre-bash-guard.sh)
assert_contains "$result" '"decision": "block"' "intercept git clean -f"
assert_contains "$result" "authorized-discard.py" "git clean -f block points to authorized discard workflow"

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

> "$VIBEGUARD_LOG_DIR/events.jsonl"
result=$(printf '{"tool_input":' | bash hooks/pre-bash-guard.sh)
assert_contains "$result" '"decision": "block"' "Malformed Bash hook JSON fails closed"
assert_contains "$(cat "$VIBEGUARD_LOG_DIR/events.jsonl")" "json-field strict failed" "Malformed Bash hook JSON writes parse warning"

result=$(echo '{"tool_input":{}}' | bash hooks/pre-bash-guard.sh)
assert_contains "$result" '"decision": "block"' "Missing Bash command field fails closed"

result=$(echo '{"tool_input":{"command":""}}' | bash hooks/pre-bash-guard.sh)
assert_not_contains "$result" '"decision": "block"' "Empty Bash command string remains a no-op"

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

result=$(python3 - <<'PY' | bash hooks/pre-bash-guard.sh
import json
print(json.dumps({"tool_input": {"command": "cat <<'EOF'\ngit checkout .\nrm -rf /\nEOF"}}))
PY
)
assert_not_contains "$result" '"decision": "block"' "heredoc body containing destructive commands is not misreported"

result=$(python3 - <<'PY' | bash hooks/pre-bash-guard.sh
import json
print(json.dumps({"tool_input": {"command": "cat <<-EOF\n\tgit checkout .\n\tEOF"}}))
PY
)
assert_not_contains "$result" '"decision": "block"' "tab-stripped heredoc body is not misreported"

result=$(python3 - <<'PY' | bash hooks/pre-bash-guard.sh
import json
print(json.dumps({"tool_input": {"command": "cat <<123\ngit checkout .\nrm -rf /\n123"}}))
PY
)
assert_not_contains "$result" '"decision": "block"' "digit-start heredoc delimiter body is not misreported"

result=$(python3 - <<'PY' | bash hooks/pre-bash-guard.sh
import json
print(json.dumps({"tool_input": {"command": "git checkout . <<'EOF'\nnot command text\nEOF"}}))
PY
)
assert_contains "$result" '"decision": "block"' "real destructive command before heredoc still blocks"

# =========================================================

hook_test_finish

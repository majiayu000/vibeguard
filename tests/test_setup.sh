#!/usr/bin/env bash
# VibeGuard setup regression testing
#
# Usage: bash tests/test_setup.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS_HELPER="${REPO_DIR}/scripts/lib/settings_json.py"
CODEX_HOOKS_HELPER="${REPO_DIR}/scripts/lib/codex_hooks_json.py"

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

assert_cmd() {
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

ORIG_HOME="${HOME}"
TMP_HOME="$(mktemp -d)"

cleanup() {
  export HOME="${ORIG_HOME}"
  rm -rf "${TMP_HOME}"
}
trap cleanup EXIT

export HOME="${TMP_HOME}"

header "setup scripts syntax"
assert_cmd "setup.sh syntax is correct" bash -n "${REPO_DIR}/setup.sh"
assert_cmd "scripts/setup/install.sh syntax is correct" bash -n "${REPO_DIR}/scripts/setup/install.sh"
assert_cmd "scripts/setup/check.sh syntax is correct" bash -n "${REPO_DIR}/scripts/setup/check.sh"
assert_cmd "scripts/setup/clean.sh syntax is correct" bash -n "${REPO_DIR}/scripts/setup/clean.sh"
assert_cmd "scripts/lib/settings_json.py syntax is correct" python3 -m py_compile "${SETTINGS_HELPER}"
assert_cmd "scripts/lib/codex_hooks_json.py syntax is correct" python3 -m py_compile "${CODEX_HOOKS_HELPER}"

header "seed legacy config"
mkdir -p "${HOME}/.claude" "${HOME}/.codex"
cat > "${HOME}/.claude/settings.json" <<'JSON'
{
  "mcpServers": {
    "vibeguard": {
      "type": "stdio",
      "command": "node",
      "args": ["/legacy/mcp-server/dist/index.js"]
    }
  },
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "mcp__vibeguard__guard_check",
        "hooks": [
          {
            "type": "command",
            "command": "bash /legacy/post-guard-check.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash /legacy/session-tagger.sh"
          }
        ]
      },
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash /legacy/cognitive-reminder.sh"
          }
        ]
      }
    ]
  }
}
JSON
cat > "${HOME}/.codex/hooks.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "node /existing/non-vibeguard.js"
          }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash /legacy/run-hook-codex.sh pre-bash-guard.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash /legacy/session-tagger.sh"
          }
        ]
      }
    ]
  }
}
JSON
cat > "${HOME}/.codex/config.toml" <<'TOML'
[mcp_servers.vibeguard]
command = "node"
args = ["/legacy/mcp-server/dist/index.js"]
TOML
assert_cmd "Legacy Claude MCP configuration has been written" grep -q "mcp-server/dist/index.js" "${HOME}/.claude/settings.json"
assert_cmd "Legacy Codex MCP configuration written" grep -q '^\[mcp_servers\.vibeguard\]' "${HOME}/.codex/config.toml"
assert_cmd "Pre-existing non-VibeGuard Codex hook is present" grep -q 'node /existing/non-vibeguard.js' "${HOME}/.codex/hooks.json"

header "setup --check"
check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
assert_contains "${check_out}" "VibeGuard Installation Status" "--check route to status check"

header "setup install"
install_out="$(bash "${REPO_DIR}/setup.sh")"
assert_contains "${install_out}" "Setup complete! All components installed." "Default route to installation process"
assert_cmd "~/.claude/skills/vibeguard exists after installation" test -L "${HOME}/.claude/skills/vibeguard"
assert_cmd "~/.codex/skills/vibeguard exists after installation" test -L "${HOME}/.codex/skills/vibeguard"
assert_cmd "Clean legacy Claude MCP block after installation" bash -c "! grep -q 'mcp-server/dist/index.js' '${HOME}/.claude/settings.json'"
assert_cmd "No longer write to mcpServers after installation" bash -c "! grep -q 'mcpServers' '${HOME}/.claude/settings.json'"
assert_cmd "settings helper detects pre hooks configured" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target pre-hooks
assert_cmd "settings helper detects post hooks configured" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target post-hooks
assert_cmd "post-guard-check is not enabled in the default installation" bash -c "! grep -q 'post-guard-check.sh' '${HOME}/.claude/settings.json'"
assert_cmd "skills-loader is not enabled in the default installation" bash -c "! grep -q 'skills-loader.sh' '${HOME}/.claude/settings.json'"
assert_cmd "The default core profile does not enable full hooks" bash -c "python3 '${SETTINGS_HELPER}' check --settings-file '${HOME}/.claude/settings.json' --target full-hooks >/dev/null 2>&1; test \$? -ne 0"
assert_cmd "~/.codex/hooks.json exists after installation" test -f "${HOME}/.codex/hooks.json"
assert_cmd "Enable codex_hooks feature after installation" grep -Eq '^codex_hooks[[:space:]]*=[[:space:]]*true$' "${HOME}/.codex/config.toml"
assert_cmd "Clean legacy Codex MCP block after installation" bash -c "! grep -q '^\[mcp_servers\.vibeguard\]' '${HOME}/.codex/config.toml'"
assert_cmd "Codex hooks are namespaced (vibeguard prefix)" bash -c "grep -q 'vibeguard-pre-bash-guard.sh' '${HOME}/.codex/hooks.json' && grep -q 'vibeguard-post-build-check.sh' '${HOME}/.codex/hooks.json' && grep -q 'vibeguard-stop-guard.sh' '${HOME}/.codex/hooks.json' && grep -q 'vibeguard-learn-evaluator.sh' '${HOME}/.codex/hooks.json'"
assert_cmd "Codex helper validates managed hooks" python3 "${CODEX_HOOKS_HELPER}" check-vibeguard --hooks-file "${HOME}/.codex/hooks.json" --wrapper "${HOME}/.vibeguard/run-hook-codex.sh"
assert_cmd "Legacy non-namespaced Codex hook command is removed" bash -c "! grep -q 'run-hook-codex.sh pre-bash-guard.sh' '${HOME}/.codex/hooks.json'"
assert_cmd "run-hook-codex rejects non-namespaced hook names" bash -c "out=\$(printf '{\"hook_event_name\":\"PreToolUse\",\"tool_input\":{\"command\":\"rm -rf /\"}}' | bash '${REPO_DIR}/hooks/run-hook-codex.sh' pre-bash-guard.sh); test -z \"\$out\""
assert_cmd "Codex hooks do not contain cognitive-reminder" bash -c "! grep -q 'cognitive-reminder.sh' '${HOME}/.codex/hooks.json'"
assert_cmd "Codex hooks do not contain session-tagger" bash -c "! grep -q 'session-tagger.sh' '${HOME}/.codex/hooks.json'"
assert_cmd "Pre-existing non-VibeGuard hook is preserved" grep -q 'node /existing/non-vibeguard.js' "${HOME}/.codex/hooks.json"
assert_cmd "Codex hooks include managed + preserved entries" python3 -c "import json; data=json.load(open('${HOME}/.codex/hooks.json')); total=sum(len(entries) for entries in data.get('hooks', {}).values() if isinstance(entries, list)); raise SystemExit(0 if total >= 5 else 1)"

header "setup --clean"
clean_out="$(bash "${REPO_DIR}/setup.sh" --clean)"
assert_contains "${clean_out}" "VibeGuard cleaned." "--clean route to cleanup process"
assert_cmd "~/.claude/skills/vibeguard has been removed after cleaning" test ! -e "${HOME}/.claude/skills/vibeguard"
assert_cmd "~/.codex/hooks.json is preserved after cleaning (for non-VibeGuard hooks)" test -f "${HOME}/.codex/hooks.json"
assert_cmd "VibeGuard managed Codex hooks removed after cleaning" bash -c "! grep -q 'vibeguard-pre-bash-guard.sh' '${HOME}/.codex/hooks.json' && ! grep -q 'vibeguard-post-build-check.sh' '${HOME}/.codex/hooks.json' && ! grep -q 'vibeguard-stop-guard.sh' '${HOME}/.codex/hooks.json' && ! grep -q 'vibeguard-learn-evaluator.sh' '${HOME}/.codex/hooks.json'"
assert_cmd "Pre-existing non-VibeGuard hook remains after cleaning" grep -q 'node /existing/non-vibeguard.js' "${HOME}/.codex/hooks.json"
assert_cmd "legacy Codex MCP block has been removed after cleaning" bash -c "[ ! -f '${HOME}/.codex/config.toml' ] || ! grep -q '^\[mcp_servers\.vibeguard\]' '${HOME}/.codex/config.toml'"

header "setup install --languages rust"
install_lang_out="$(bash "${REPO_DIR}/setup.sh" --profile core --languages rust)"
assert_contains "${install_lang_out}" "Languages: rust" "--languages parameter takes effect"
assert_cmd "--languages after installation --check executable" bash -c "bash '${REPO_DIR}/setup.sh' --check >/dev/null 2>&1"

header "setup --clean (after --languages)"
clean_lang_out="$(bash "${REPO_DIR}/setup.sh" --clean)"
assert_contains "${clean_lang_out}" "VibeGuard cleaned." "languages profile cleaned successfully"

header "setup install --profile full"
install_full_out="$(bash "${REPO_DIR}/setup.sh" --profile full)"
assert_contains "${install_full_out}" "Profile: full" "full profile parameter takes effect"
assert_cmd "full profile configuration full hooks" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target full-hooks
assert_cmd "full profile enable stop-guard" grep -q "stop-guard.sh" "${HOME}/.claude/settings.json"
assert_cmd "full profile enable learn-evaluator" grep -q "learn-evaluator.sh" "${HOME}/.claude/settings.json"
assert_cmd "full profile enable post-build-check" grep -q "post-build-check.sh" "${HOME}/.claude/settings.json"

header "setup --clean (after full)"
clean_full_out="$(bash "${REPO_DIR}/setup.sh" --clean)"
assert_contains "${clean_full_out}" "VibeGuard cleaned." "full profile cleaned successfully"
assert_cmd "full hooks have been removed after cleaning" bash -c "python3 '${SETTINGS_HELPER}' check --settings-file '${HOME}/.claude/settings.json' --target full-hooks >/dev/null 2>&1; test \$? -ne 0"

header "setup install --profile strict"
install_strict_out="$(bash "${REPO_DIR}/setup.sh" --profile strict)"
assert_contains "${install_strict_out}" "Profile: strict" "strict profile parameter takes effect"
assert_cmd "strict profile still configures full hooks" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target full-hooks
assert_cmd "strict profile does not enable session-tagger" bash -c "! grep -q 'session-tagger.sh' '${HOME}/.claude/settings.json' && ! grep -q 'session-tagger.sh' '${HOME}/.codex/hooks.json'"
assert_cmd "strict profile does not enable cognitive-reminder" bash -c "! grep -q 'cognitive-reminder.sh' '${HOME}/.claude/settings.json' && ! grep -q 'cognitive-reminder.sh' '${HOME}/.codex/hooks.json'"

header "setup --clean (after strict)"
clean_strict_out="$(bash "${REPO_DIR}/setup.sh" --clean)"
assert_contains "${clean_strict_out}" "VibeGuard cleaned." "strict profile cleaned successfully"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

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
assert_cmd "scripts/install-systemd.sh syntax is correct" bash -n "${REPO_DIR}/scripts/install-systemd.sh"
assert_cmd "scripts/lib/settings_json.py syntax is correct" python3 -m py_compile "${SETTINGS_HELPER}"
assert_cmd "scripts/lib/codex_hooks_json.py syntax is correct" python3 -m py_compile "${CODEX_HOOKS_HELPER}"

header "scheduled GC templates"
assert_cmd "scheduled GC script exists at canonical path" test -x "${REPO_DIR}/scripts/gc/gc-scheduled.sh"
assert_cmd "launchd plist points to canonical GC script path" grep -q "__VIBEGUARD_DIR__/scripts/gc/gc-scheduled.sh" "${REPO_DIR}/scripts/setup/com.vibeguard.gc.plist"
assert_cmd "systemd service points to canonical GC script path" grep -q "__VIBEGUARD_DIR__/scripts/gc/gc-scheduled.sh" "${REPO_DIR}/scripts/systemd/vibeguard-gc.service"
assert_cmd "systemd installer chmods canonical GC script path" grep -q 'scripts/gc/gc-scheduled.sh' "${REPO_DIR}/scripts/install-systemd.sh"
assert_cmd "scheduled GC installers do not reference legacy root path" bash -c "! grep -q 'scripts/gc-scheduled.sh' '${REPO_DIR}/scripts/setup/com.vibeguard.gc.plist' '${REPO_DIR}/scripts/systemd/vibeguard-gc.service' '${REPO_DIR}/scripts/install-systemd.sh'"

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
assert_cmd "~/.claude/skills/agentsmd-audit exists after installation" test -L "${HOME}/.claude/skills/agentsmd-audit"
assert_cmd "~/.claude/skills/trajectory-review exists after installation" test -L "${HOME}/.claude/skills/trajectory-review"
assert_cmd "~/.codex/skills/agentsmd-audit exists after installation" test -L "${HOME}/.codex/skills/agentsmd-audit"
assert_cmd "~/.codex/skills/trajectory-review exists after installation" test -L "${HOME}/.codex/skills/trajectory-review"
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

header "codex config helper failure propagates"
_ORIG_CODEX_CONFIG_HELPER="${REPO_DIR}/scripts/lib/codex_config_toml.py"
_BACKUP_CODEX_CONFIG_HELPER="${TMP_HOME}/codex_config_toml.py.backup"
cp "${_ORIG_CODEX_CONFIG_HELPER}" "${_BACKUP_CODEX_CONFIG_HELPER}"
cat > "${_ORIG_CODEX_CONFIG_HELPER}" <<'PY'
#!/usr/bin/env python3
raise SystemExit(42)
PY
fail_install_out="$(bash "${REPO_DIR}/setup.sh" 2>&1 || true)"
cp "${_BACKUP_CODEX_CONFIG_HELPER}" "${_ORIG_CODEX_CONFIG_HELPER}"
assert_contains "${fail_install_out}" "Failed to enable codex_hooks feature in config.toml" "setup reports codex_hooks helper failure"
assert_cmd "setup exits before reporting success when codex_hooks helper fails" bash -c "! grep -q 'Setup complete! All components installed.' <<< '${fail_install_out}'"

header "setup --check stays read-only"
python3 - <<'PY' "${HOME}/.claude/CLAUDE.md"
from pathlib import Path
import re
path = Path(__import__('sys').argv[1])
text = path.read_text(encoding='utf-8')
updated = re.sub(r'\b\d+ rules\b', '999 rules', text, count=1)
path.write_text(updated, encoding='utf-8')
PY
before_sha="$(shasum -a 256 "${HOME}/.claude/CLAUDE.md" | cut -d' ' -f1)"
check_again_out="$(bash "${REPO_DIR}/setup.sh" --check)"
after_sha="$(shasum -a 256 "${HOME}/.claude/CLAUDE.md" | cut -d' ' -f1)"
assert_contains "${check_again_out}" "CLAUDE.md declares 999 rules" "--check reports CLAUDE.md drift"
assert_cmd "--check does not rewrite ~/.claude/CLAUDE.md" test "${before_sha}" = "${after_sha}"

header "upsert idempotency with non-standard wrapper path"
# Run upsert twice with a wrapper path that does not contain 'run-hook-codex.sh'.
# Without the _has_entry dedup fix, the second upsert would append duplicates.
_IDEMPOTENT_HOOKS="${TMP_HOME}/.codex/hooks-idempotent.json"
_IDEMPOTENT_WRAPPER="${TMP_HOME}/test/wrapper.sh"
python3 "${CODEX_HOOKS_HELPER}" upsert-vibeguard --hooks-file "${_IDEMPOTENT_HOOKS}" --wrapper "${_IDEMPOTENT_WRAPPER}" >/dev/null
python3 "${CODEX_HOOKS_HELPER}" upsert-vibeguard --hooks-file "${_IDEMPOTENT_HOOKS}" --wrapper "${_IDEMPOTENT_WRAPPER}" >/dev/null
assert_cmd "double-upsert with non-standard wrapper produces exactly 4 Stop entries (not 8)" python3 -c "
import json
data = json.load(open('${_IDEMPOTENT_HOOKS}'))
stop_entries = data.get('hooks', {}).get('Stop', [])
raise SystemExit(0 if len(stop_entries) == 2 else 1)
"
assert_cmd "double-upsert with non-standard wrapper: check-vibeguard passes" python3 "${CODEX_HOOKS_HELPER}" check-vibeguard --hooks-file "${_IDEMPOTENT_HOOKS}" --wrapper "${_IDEMPOTENT_WRAPPER}"

header "remove-vibeguard cleans custom-wrapper-path hooks"
# Issue fix: _is_vibeguard_command must recognise vibeguard-* scripts even when
# the wrapper path does not contain 'run-hook-codex.sh'.
python3 "${CODEX_HOOKS_HELPER}" remove-vibeguard --hooks-file "${_IDEMPOTENT_HOOKS}"
assert_cmd "remove-vibeguard removes custom-wrapper vibeguard hooks" bash -c "! grep -q 'vibeguard-pre-bash-guard.sh' '${_IDEMPOTENT_HOOKS}'"
assert_cmd "remove-vibeguard removes all managed hook scripts" bash -c "! grep -qE 'vibeguard-(pre-bash-guard|post-build-check|stop-guard|learn-evaluator)\\.sh' '${_IDEMPOTENT_HOOKS}'"

header "_has_entry validates type and timeout (Issue 2 guard)"
# A stale entry that has the correct command but is missing 'type: command' or
# has a spurious timeout must NOT satisfy check-vibeguard (silent false positive).
_STALE_HOOKS="${TMP_HOME}/.codex/hooks-stale.json"
_STALE_WRAPPER="${TMP_HOME}/test/stale-wrapper.sh"
# Write an entry with correct command but no 'type' field and no 'timeout'.
python3 -c "
import json, sys
data = {
  'hooks': {
    'PreToolUse': [{
      'matcher': 'Bash',
      'hooks': [{'command': 'bash ${_STALE_WRAPPER} vibeguard-pre-bash-guard.sh'}]
    }]
  }
}
with open('${_STALE_HOOKS}', 'w') as f:
    json.dump(data, f, indent=2)
"
assert_cmd "check-vibeguard rejects stale entry missing type field" bash -c "! python3 '${CODEX_HOOKS_HELPER}' check-vibeguard --hooks-file '${_STALE_HOOKS}' --wrapper '${_STALE_WRAPPER}'"
# After upsert the entry must be repaired and check must pass.
python3 "${CODEX_HOOKS_HELPER}" upsert-vibeguard --hooks-file "${_STALE_HOOKS}" --wrapper "${_STALE_WRAPPER}" >/dev/null
assert_cmd "upsert repairs stale entry; check-vibeguard then passes" python3 "${CODEX_HOOKS_HELPER}" check-vibeguard --hooks-file "${_STALE_HOOKS}" --wrapper "${_STALE_WRAPPER}"
# Write a Stop entry with correct command but a spurious timeout (Stop spec has none).
python3 -c "
import json
data = {
  'hooks': {
    'Stop': [{
      'hooks': [{'type': 'command', 'command': 'bash ${_STALE_WRAPPER} vibeguard-stop-guard.sh', 'timeout': 99}]
    }]
  }
}
with open('${_STALE_HOOKS}', 'w') as f:
    json.dump(data, f, indent=2)
"
assert_cmd "check-vibeguard rejects Stop entry with spurious timeout" bash -c "! python3 '${CODEX_HOOKS_HELPER}' check-vibeguard --hooks-file '${_STALE_HOOKS}' --wrapper '${_STALE_WRAPPER}'"
# Write a Stop entry with correct command+type but a spurious matcher (Stop spec has none).
python3 -c "
import json
data = {
  'hooks': {
    'Stop': [{
      'matcher': 'Bash',
      'hooks': [{'type': 'command', 'command': 'bash ${_STALE_WRAPPER} vibeguard-stop-guard.sh'}]
    }]
  }
}
with open('${_STALE_HOOKS}', 'w') as f:
    json.dump(data, f, indent=2)
"
assert_cmd "check-vibeguard rejects Stop entry with spurious matcher" bash -c "! python3 '${CODEX_HOOKS_HELPER}' check-vibeguard --hooks-file '${_STALE_HOOKS}' --wrapper '${_STALE_WRAPPER}'"
# After upsert the entry must be repaired and check must pass.
python3 "${CODEX_HOOKS_HELPER}" upsert-vibeguard --hooks-file "${_STALE_HOOKS}" --wrapper "${_STALE_WRAPPER}" >/dev/null
assert_cmd "upsert repairs Stop entry with spurious matcher; check-vibeguard then passes" python3 "${CODEX_HOOKS_HELPER}" check-vibeguard --hooks-file "${_STALE_HOOKS}" --wrapper "${_STALE_WRAPPER}"

header "setup --clean"
clean_out="$(bash "${REPO_DIR}/setup.sh" --clean)"
assert_contains "${clean_out}" "VibeGuard cleaned." "--clean route to cleanup process"
assert_cmd "~/.claude/skills/vibeguard has been removed after cleaning" test ! -e "${HOME}/.claude/skills/vibeguard"
assert_cmd "~/.claude/skills/agentsmd-audit has been removed after cleaning" test ! -e "${HOME}/.claude/skills/agentsmd-audit"
assert_cmd "~/.claude/skills/trajectory-review has been removed after cleaning" test ! -e "${HOME}/.claude/skills/trajectory-review"
assert_cmd "~/.codex/skills/agentsmd-audit has been removed after cleaning" test ! -e "${HOME}/.codex/skills/agentsmd-audit"
assert_cmd "~/.codex/skills/trajectory-review has been removed after cleaning" test ! -e "${HOME}/.codex/skills/trajectory-review"
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

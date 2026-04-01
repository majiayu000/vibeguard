#!/usr/bin/env bash
# VibeGuard setup 回归测试
#
# 用法：bash tests/test_setup.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS_HELPER="${REPO_DIR}/scripts/lib/settings_json.py"

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
assert_cmd "setup.sh 语法正确" bash -n "${REPO_DIR}/setup.sh"
assert_cmd "scripts/setup/install.sh 语法正确" bash -n "${REPO_DIR}/scripts/setup/install.sh"
assert_cmd "scripts/setup/check.sh 语法正确" bash -n "${REPO_DIR}/scripts/setup/check.sh"
assert_cmd "scripts/setup/clean.sh 语法正确" bash -n "${REPO_DIR}/scripts/setup/clean.sh"
assert_cmd "scripts/lib/settings_json.py 语法正确" python3 -m py_compile "${SETTINGS_HELPER}"

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
cat > "${HOME}/.codex/config.toml" <<'TOML'
[mcp_servers.vibeguard]
command = "node"
args = ["/legacy/mcp-server/dist/index.js"]
TOML
assert_cmd "已写入 legacy Claude MCP 配置" grep -q "mcp-server/dist/index.js" "${HOME}/.claude/settings.json"
assert_cmd "已写入 legacy Codex MCP 配置" grep -q '^\[mcp_servers\.vibeguard\]' "${HOME}/.codex/config.toml"

header "setup --check"
check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
assert_contains "${check_out}" "VibeGuard Installation Status" "--check 路由到状态检查"

header "setup install"
install_out="$(bash "${REPO_DIR}/setup.sh")"
assert_contains "${install_out}" "Setup complete! All components installed." "默认路由到安装流程"
assert_cmd "安装后 ~/.claude/skills/vibeguard 存在" test -L "${HOME}/.claude/skills/vibeguard"
assert_cmd "安装后 ~/.codex/skills/vibeguard 存在" test -L "${HOME}/.codex/skills/vibeguard"
assert_cmd "安装后清理 legacy Claude MCP block" bash -c "! grep -q 'mcp-server/dist/index.js' '${HOME}/.claude/settings.json'"
assert_cmd "安装后不再写入 mcpServers" bash -c "! grep -q 'mcpServers' '${HOME}/.claude/settings.json'"
assert_cmd "settings helper 检测 pre hooks 已配置" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target pre-hooks
assert_cmd "settings helper 检测 post hooks 已配置" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target post-hooks
assert_cmd "默认安装不启用 post-guard-check" bash -c "! grep -q 'post-guard-check.sh' '${HOME}/.claude/settings.json'"
assert_cmd "默认安装不启用 skills-loader" bash -c "! grep -q 'skills-loader.sh' '${HOME}/.claude/settings.json'"
assert_cmd "默认 core profile 不启用 full hooks" bash -c "python3 '${SETTINGS_HELPER}' check --settings-file '${HOME}/.claude/settings.json' --target full-hooks >/dev/null 2>&1; test \$? -ne 0"
assert_cmd "安装后存在 ~/.codex/hooks.json" test -f "${HOME}/.codex/hooks.json"
assert_cmd "安装后启用 codex_hooks feature" grep -Eq '^codex_hooks[[:space:]]*=[[:space:]]*true$' "${HOME}/.codex/config.toml"
assert_cmd "安装后清理 legacy Codex MCP block" bash -c "! grep -q '^\[mcp_servers\.vibeguard\]' '${HOME}/.codex/config.toml'"
assert_cmd "Codex hooks 不包含 cognitive-reminder" bash -c "! grep -q 'cognitive-reminder.sh' '${HOME}/.codex/hooks.json'"
assert_cmd "Codex hooks 不包含 session-tagger" bash -c "! grep -q 'session-tagger.sh' '${HOME}/.codex/hooks.json'"
assert_cmd "Codex hooks 数量为 4" python3 -c "import json; data=json.load(open('${HOME}/.codex/hooks.json')); total=sum(len(entries) for entries in data.get('hooks', {}).values()); raise SystemExit(0 if total == 4 else 1)"

header "setup --clean"
clean_out="$(bash "${REPO_DIR}/setup.sh" --clean)"
assert_contains "${clean_out}" "VibeGuard cleaned." "--clean 路由到清理流程"
assert_cmd "清理后 ~/.claude/skills/vibeguard 已移除" test ! -e "${HOME}/.claude/skills/vibeguard"
assert_cmd "清理后 ~/.codex/hooks.json 已移除" test ! -e "${HOME}/.codex/hooks.json"
assert_cmd "清理后 legacy Codex MCP block 已移除" bash -c "[ ! -f '${HOME}/.codex/config.toml' ] || ! grep -q '^\[mcp_servers\.vibeguard\]' '${HOME}/.codex/config.toml'"

header "setup install --languages rust"
install_lang_out="$(bash "${REPO_DIR}/setup.sh" --profile core --languages rust)"
assert_contains "${install_lang_out}" "Languages: rust" "--languages 参数生效"
assert_cmd "--languages 安装后 --check 可执行" bash -c "bash '${REPO_DIR}/setup.sh' --check >/dev/null 2>&1"

header "setup --clean (after --languages)"
clean_lang_out="$(bash "${REPO_DIR}/setup.sh" --clean)"
assert_contains "${clean_lang_out}" "VibeGuard cleaned." "languages profile 清理成功"

header "setup install --profile full"
install_full_out="$(bash "${REPO_DIR}/setup.sh" --profile full)"
assert_contains "${install_full_out}" "Profile: full" "full profile 参数生效"
assert_cmd "full profile 配置 full hooks" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target full-hooks
assert_cmd "full profile 启用 stop-guard" grep -q "stop-guard.sh" "${HOME}/.claude/settings.json"
assert_cmd "full profile 启用 learn-evaluator" grep -q "learn-evaluator.sh" "${HOME}/.claude/settings.json"
assert_cmd "full profile 启用 post-build-check" grep -q "post-build-check.sh" "${HOME}/.claude/settings.json"

header "setup --clean (after full)"
clean_full_out="$(bash "${REPO_DIR}/setup.sh" --clean)"
assert_contains "${clean_full_out}" "VibeGuard cleaned." "full profile 清理成功"
assert_cmd "清理后 full hooks 已移除" bash -c "python3 '${SETTINGS_HELPER}' check --settings-file '${HOME}/.claude/settings.json' --target full-hooks >/dev/null 2>&1; test \$? -ne 0"

header "setup install --profile strict"
install_strict_out="$(bash "${REPO_DIR}/setup.sh" --profile strict)"
assert_contains "${install_strict_out}" "Profile: strict" "strict profile 参数生效"
assert_cmd "strict profile 仍配置 full hooks" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target full-hooks
assert_cmd "strict profile 不启用 session-tagger" bash -c "! grep -q 'session-tagger.sh' '${HOME}/.claude/settings.json' && ! grep -q 'session-tagger.sh' '${HOME}/.codex/hooks.json'"
assert_cmd "strict profile 不启用 cognitive-reminder" bash -c "! grep -q 'cognitive-reminder.sh' '${HOME}/.claude/settings.json' && ! grep -q 'cognitive-reminder.sh' '${HOME}/.codex/hooks.json'"

header "setup --clean (after strict)"
clean_strict_out="$(bash "${REPO_DIR}/setup.sh" --clean)"
assert_contains "${clean_strict_out}" "VibeGuard cleaned." "strict profile 清理成功"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

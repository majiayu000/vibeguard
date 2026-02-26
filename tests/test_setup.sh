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
CREATED_DIST=0

cleanup() {
  export HOME="${ORIG_HOME}"
  if [[ "${CREATED_DIST}" -eq 1 ]]; then
    rm -f "${REPO_DIR}/mcp-server/dist/index.js"
    rmdir "${REPO_DIR}/mcp-server/dist" 2>/dev/null || true
  fi
  rm -rf "${TMP_HOME}"
}
trap cleanup EXIT

export HOME="${TMP_HOME}"

header "setup scripts syntax"
assert_cmd "setup.sh 语法正确" bash -n "${REPO_DIR}/setup.sh"
assert_cmd "scripts/setup/install.sh 语法正确" bash -n "${REPO_DIR}/scripts/setup/install.sh"
assert_cmd "scripts/setup/check.sh 语法正确" bash -n "${REPO_DIR}/scripts/setup/check.sh"
assert_cmd "scripts/setup/clean.sh 语法正确" bash -n "${REPO_DIR}/scripts/setup/clean.sh"

# 保证 install 测试可跳过构建（如果 dist 不存在则放一个最小占位）
if [[ ! -f "${REPO_DIR}/mcp-server/dist/index.js" ]]; then
  mkdir -p "${REPO_DIR}/mcp-server/dist"
  printf '%s\n' 'console.log("vibeguard test stub");' > "${REPO_DIR}/mcp-server/dist/index.js"
  CREATED_DIST=1
fi
touch "${REPO_DIR}/mcp-server/dist/index.js"

header "setup --check"
check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
assert_contains "${check_out}" "VibeGuard Installation Status" "--check 路由到状态检查"

header "setup install"
install_out="$(bash "${REPO_DIR}/setup.sh")"
assert_contains "${install_out}" "Setup complete! All components installed." "默认路由到安装流程"
assert_cmd "安装后 ~/.claude/skills/vibeguard 存在" test -L "${HOME}/.claude/skills/vibeguard"
assert_cmd "安装后 ~/.codex/skills/vibeguard 存在" test -L "${HOME}/.codex/skills/vibeguard"
assert_cmd "settings helper 检测 mcp 已配置" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target mcp
assert_cmd "settings helper 检测 pre hooks 已配置" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target pre-hooks
assert_cmd "settings helper 检测 post hooks 已配置" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target post-hooks

header "setup --clean"
clean_out="$(bash "${REPO_DIR}/setup.sh" --clean)"
assert_contains "${clean_out}" "VibeGuard cleaned." "--clean 路由到清理流程"
assert_cmd "清理后 ~/.claude/skills/vibeguard 已移除" test ! -e "${HOME}/.claude/skills/vibeguard"
assert_cmd "清理后 settings mcp 已移除" bash -c "python3 '${SETTINGS_HELPER}' check --settings-file '${HOME}/.claude/settings.json' --target mcp >/dev/null 2>&1; test \$? -ne 0"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

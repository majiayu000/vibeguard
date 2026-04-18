#!/usr/bin/env bash
# VibeGuard manifest contract regression tests
#
# Usage: bash tests/test_manifest_contract.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST_HELPER="${REPO_DIR}/scripts/lib/vibeguard_manifest.py"
CODEX_CONFIG_HELPER="${REPO_DIR}/scripts/lib/codex_config_toml.py"

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header(){ printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

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

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

header "helper syntax"
assert_cmd "manifest helper syntax is correct" python3 -m py_compile "${MANIFEST_HELPER}"
assert_cmd "codex config helper syntax is correct" python3 -m py_compile "${CODEX_CONFIG_HELPER}"

header "manifest contract"
assert_cmd "manifest contract validates" python3 "${MANIFEST_HELPER}" validate
profiles_out="$(python3 "${MANIFEST_HELPER}" profile-names)"
assert_contains "${profiles_out}" "core" "profile list contains core"
assert_contains "${profiles_out}" "full" "profile list contains full"
rules_out="$(python3 "${MANIFEST_HELPER}" rule-ids --source canonical --scope common)"
assert_contains "${rules_out}" "W-17" "canonical common rule ids include W-17"
assert_contains "${rules_out}" "U-32" "canonical common rule ids include U-32"

header "codex config helper"
CONFIG_FILE="${TMP_DIR}/config.toml"
enable_out="$(python3 "${CODEX_CONFIG_HELPER}" enable-codex-hooks --config-file "${CONFIG_FILE}")"
assert_contains "${enable_out}" "CHANGED" "enable-codex-hooks creates config when missing"
assert_cmd "enable-codex-hooks writes codex_hooks = true" grep -Eq '^codex_hooks[[:space:]]*=[[:space:]]*true$' "${CONFIG_FILE}"

cat > "${CONFIG_FILE}" <<'TOML'
[features]
foo = true

[mcp_servers.vibeguard]
command = "node"
args = ["/legacy/mcp-server/dist/index.js"]
TOML
remove_out="$(python3 "${CODEX_CONFIG_HELPER}" remove-legacy-vibeguard-mcp --config-file "${CONFIG_FILE}")"
assert_contains "${remove_out}" "CHANGED" "remove-legacy-vibeguard-mcp reports change"
assert_cmd "legacy vibeguard mcp section removed" bash -c "! grep -q '^\[mcp_servers\\.vibeguard\]' '${CONFIG_FILE}'"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

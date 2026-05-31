#!/usr/bin/env bash
# VibeGuard Guard Pack regression tests
#
# Usage: bash tests/test_guard_packs.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GUARD_PACKS_HELPER="${REPO_DIR}/scripts/lib/guard_packs.py"

PASS=0
FAIL=0
TOTAL=0
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

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

assert_cmd_fail() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    red "$desc (expected failure)"
    FAIL=$((FAIL + 1))
  else
    green "$desc"
    PASS=$((PASS + 1))
  fi
}

assert_contains() {
  local output="$1" expected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qF -- "$expected" <<< "${output}"; then
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
  if grep -qF -- "$unexpected" <<< "${output}"; then
    red "$desc (unexpected content: $unexpected)"
    FAIL=$((FAIL + 1))
  else
    green "$desc"
    PASS=$((PASS + 1))
  fi
}

header "syntax"
assert_cmd "guard packs helper syntax is correct" python3 -m py_compile "${GUARD_PACKS_HELPER}"
assert_cmd "guard-packs setup route syntax is correct" bash -n "${REPO_DIR}/scripts/setup/guard-packs.sh"

header "manifest"
assert_cmd "guard pack manifests validate" python3 "${GUARD_PACKS_HELPER}" validate
guard_packs_out="$(python3 "${GUARD_PACKS_HELPER}" list)"
assert_contains "${guard_packs_out}" "safe-bash" "guard pack list contains safe-bash"

safe_bash_explain_out="$(python3 "${GUARD_PACKS_HELPER}" explain safe-bash)"
assert_contains "${safe_bash_explain_out}" "Guard Packs are an adoption layer" "safe-bash explain states adoption boundary"
assert_contains "${safe_bash_explain_out}" "hooks/pre-bash-guard.sh" "safe-bash explain points to source hook"
assert_contains "${safe_bash_explain_out}" "claude-code: native" "safe-bash explain declares Claude Code target"
assert_contains "${safe_bash_explain_out}" "codex: native" "safe-bash explain declares Codex target"
assert_cmd_fail "guard pack explain rejects unknown pack" python3 "${GUARD_PACKS_HELPER}" explain missing-pack
assert_cmd_fail "guard pack install rejects partial target" python3 "${GUARD_PACKS_HELPER}" install --target generic-cli --pack safe-bash --dry-run

header "dry-run"
safe_bash_dry_run_out="$(python3 "${GUARD_PACKS_HELPER}" install --target claude-code --pack safe-bash --dry-run)"
assert_contains "${safe_bash_dry_run_out}" "DRY-RUN: install guard pack safe-bash for claude-code" "safe-bash install dry-run reports target"
assert_contains "${safe_bash_dry_run_out}" "Would modify:" "safe-bash dry-run shows planned writes"
assert_contains "${safe_bash_dry_run_out}" "writes=0" "safe-bash dry-run receipt records no writes"
assert_contains "${safe_bash_dry_run_out}" "Rollback plan:" "safe-bash dry-run prints rollback plan"
assert_contains "${safe_bash_dry_run_out}" "Audit command:" "safe-bash dry-run prints audit command"
assert_cmd_fail "guard pack install rejects incomplete target" python3 "${GUARD_PACKS_HELPER}" install --target claude-code --pack safe-bash --home "${TMP_DIR}/missing-install-home"

header "receipt"
safe_bash_receipt_out="$(python3 "${GUARD_PACKS_HELPER}" receipt safe-bash --target claude-code)"
assert_contains "${safe_bash_receipt_out}" '"type": "guard_pack_install_receipt_preview"' "receipt has preview type"
assert_contains "${safe_bash_receipt_out}" '"dry_run": true' "receipt records dry-run"
assert_contains "${safe_bash_receipt_out}" '"writes": 0' "receipt records zero writes"
assert_contains "${safe_bash_receipt_out}" '"receipt_path": "~/.vibeguard/guard-packs/safe-bash/claude-code/receipt.json"' "receipt records future path"
assert_contains "${safe_bash_receipt_out}" '"rollback_plan": [' "receipt includes rollback plan"
assert_cmd_fail "guard pack receipt rejects partial target" python3 "${GUARD_PACKS_HELPER}" receipt safe-bash --target generic-cli
assert_cmd "receipt JSON parses and keeps plan fields" python3 -c '
import json
import sys
data = json.loads(sys.stdin.read())
assert data["pack"]["id"] == "safe-bash"
assert data["target"] == "claude-code"
assert data["plan"]["would_modify"] == ["~/.claude/settings.json"]
assert data["audit"]["check_ids"] == [
    "runtime-binary",
    "installed-pre-bash-hook",
    "claude-wrapper",
    "claude-pre-bash-config",
]
' <<< "${safe_bash_receipt_out}"

header "audit"
audit_missing_home="${TMP_DIR}/audit-missing-home"
mkdir -p "${audit_missing_home}"
audit_missing_out="$(python3 "${GUARD_PACKS_HELPER}" audit safe-bash --target claude-code --home "${audit_missing_home}" 2>&1 || true)"
assert_contains "${audit_missing_out}" "Status: INCOMPLETE" "audit reports incomplete target"
assert_contains "${audit_missing_out}" "MISSING runtime-binary" "audit reports missing runtime"
assert_cmd_fail "audit exits non-zero when target incomplete" python3 "${GUARD_PACKS_HELPER}" audit safe-bash --target claude-code --home "${audit_missing_home}"

audit_ready_home="${TMP_DIR}/audit-ready-home"
mkdir -p \
  "${audit_ready_home}/.vibeguard/installed/bin" \
  "${audit_ready_home}/.vibeguard/installed/hooks" \
  "${audit_ready_home}/.claude"
touch "${audit_ready_home}/.vibeguard/installed/bin/vibeguard-runtime"
chmod +x "${audit_ready_home}/.vibeguard/installed/bin/vibeguard-runtime"
touch "${audit_ready_home}/.vibeguard/installed/hooks/pre-bash-guard.sh"
touch "${audit_ready_home}/.vibeguard/run-hook.sh"
chmod +x "${audit_ready_home}/.vibeguard/run-hook.sh"
cat > "${audit_ready_home}/.claude/settings.json" <<JSON
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${audit_ready_home}/.vibeguard/run-hook.sh pre-bash-guard.sh"
          }
        ]
      }
    ]
  }
}
JSON
audit_ready_out="$(python3 "${GUARD_PACKS_HELPER}" audit safe-bash --target claude-code --home "${audit_ready_home}")"
assert_contains "${audit_ready_out}" "Status: READY" "audit reports ready Claude target"
assert_contains "${audit_ready_out}" "OK claude-pre-bash-config" "audit reports Claude hook config"

audit_fake_home="${TMP_DIR}/audit-fake-home"
mkdir -p \
  "${audit_fake_home}/.vibeguard/installed/bin" \
  "${audit_fake_home}/.vibeguard/installed/hooks" \
  "${audit_fake_home}/.claude"
touch "${audit_fake_home}/.vibeguard/installed/bin/vibeguard-runtime"
chmod +x "${audit_fake_home}/.vibeguard/installed/bin/vibeguard-runtime"
touch "${audit_fake_home}/.vibeguard/installed/hooks/pre-bash-guard.sh"
touch "${audit_fake_home}/.vibeguard/run-hook.sh"
chmod +x "${audit_fake_home}/.vibeguard/run-hook.sh"
cat > "${audit_fake_home}/.claude/settings.json" <<JSON
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "echo ${audit_fake_home}/.vibeguard/run-hook.sh pre-bash-guard.sh"
          }
        ]
      }
    ]
  }
}
JSON
audit_fake_out="$(python3 "${GUARD_PACKS_HELPER}" audit safe-bash --target claude-code --home "${audit_fake_home}" 2>&1 || true)"
assert_contains "${audit_fake_out}" "Status: INCOMPLETE" "audit rejects non-VibeGuard command containing script name"
assert_contains "${audit_fake_out}" "MISSING claude-pre-bash-config" "audit reports fake Claude hook as missing"
assert_cmd_fail "audit exits non-zero for fake hook command" python3 "${GUARD_PACKS_HELPER}" audit safe-bash --target claude-code --home "${audit_fake_home}"

audit_external_wrapper_home="${TMP_DIR}/audit-external-wrapper-home"
external_wrapper="${TMP_DIR}/outside/run-hook.sh"
mkdir -p \
  "${audit_external_wrapper_home}/.vibeguard/installed/bin" \
  "${audit_external_wrapper_home}/.vibeguard/installed/hooks" \
  "${audit_external_wrapper_home}/.claude" \
  "$(dirname "${external_wrapper}")"
touch "${audit_external_wrapper_home}/.vibeguard/installed/bin/vibeguard-runtime"
chmod +x "${audit_external_wrapper_home}/.vibeguard/installed/bin/vibeguard-runtime"
touch "${audit_external_wrapper_home}/.vibeguard/installed/hooks/pre-bash-guard.sh"
touch "${audit_external_wrapper_home}/.vibeguard/run-hook.sh" "${external_wrapper}"
chmod +x "${audit_external_wrapper_home}/.vibeguard/run-hook.sh" "${external_wrapper}"
cat > "${audit_external_wrapper_home}/.claude/settings.json" <<JSON
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${external_wrapper} pre-bash-guard.sh"
          }
        ]
      }
    ]
  }
}
JSON
audit_external_wrapper_out="$(python3 "${GUARD_PACKS_HELPER}" audit safe-bash --target claude-code --home "${audit_external_wrapper_home}" 2>&1 || true)"
assert_contains "${audit_external_wrapper_out}" "Status: INCOMPLETE" "audit rejects same-name wrapper outside VibeGuard home"
assert_contains "${audit_external_wrapper_out}" "MISSING claude-pre-bash-config" "audit reports external wrapper config as missing"
assert_cmd_fail "audit exits non-zero for external wrapper command" python3 "${GUARD_PACKS_HELPER}" audit safe-bash --target claude-code --home "${audit_external_wrapper_home}"

audit_missing_type_home="${TMP_DIR}/audit-missing-type-home"
mkdir -p \
  "${audit_missing_type_home}/.vibeguard/installed/bin" \
  "${audit_missing_type_home}/.vibeguard/installed/hooks" \
  "${audit_missing_type_home}/.claude"
touch "${audit_missing_type_home}/.vibeguard/installed/bin/vibeguard-runtime"
chmod +x "${audit_missing_type_home}/.vibeguard/installed/bin/vibeguard-runtime"
touch "${audit_missing_type_home}/.vibeguard/installed/hooks/pre-bash-guard.sh"
touch "${audit_missing_type_home}/.vibeguard/run-hook.sh"
chmod +x "${audit_missing_type_home}/.vibeguard/run-hook.sh"
cat > "${audit_missing_type_home}/.claude/settings.json" <<JSON
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "command": "bash ${audit_missing_type_home}/.vibeguard/run-hook.sh pre-bash-guard.sh"
          }
        ]
      }
    ]
  }
}
JSON
audit_missing_type_out="$(python3 "${GUARD_PACKS_HELPER}" audit safe-bash --target claude-code --home "${audit_missing_type_home}" 2>&1 || true)"
assert_contains "${audit_missing_type_out}" "Status: INCOMPLETE" "audit rejects hook entries without command type"

header "install and uninstall"
install_missing_out="$(python3 "${GUARD_PACKS_HELPER}" install --target claude-code --pack safe-bash --home "${audit_missing_home}" 2>&1 || true)"
assert_contains "${install_missing_out}" "audit is INCOMPLETE" "install refuses incomplete target"
if [[ -e "${audit_missing_home}/.vibeguard/guard-packs/safe-bash/claude-code/receipt.json" ]]; then
  red "install did not write receipt for incomplete target"
  FAIL=$((FAIL + 1))
else
  green "install does not write receipt for incomplete target"
  PASS=$((PASS + 1))
fi
TOTAL=$((TOTAL + 1))

install_ready_out="$(python3 "${GUARD_PACKS_HELPER}" install --target claude-code --pack safe-bash --home "${audit_ready_home}")"
assert_contains "${install_ready_out}" "INSTALLED: guard pack safe-bash registered for claude-code" "install registers ready target"
assert_contains "${install_ready_out}" "No hook/config files were modified" "install states config boundary"
assert_cmd "install writes receipt file" test -f "${audit_ready_home}/.vibeguard/guard-packs/safe-bash/claude-code/receipt.json"
assert_cmd "installed receipt JSON records write boundary" python3 -c '
import json
from pathlib import Path
data = json.loads(Path("'"${audit_ready_home}"'/.vibeguard/guard-packs/safe-bash/claude-code/receipt.json").read_text())
assert data["type"] == "guard_pack_install_receipt"
assert data["dry_run"] is False
assert data["writes"] == 1
assert data["actual_writes"] == ["~/.vibeguard/guard-packs/safe-bash/claude-code/receipt.json"]
assert data["audit_snapshot"]["status"] == "READY"
'
uninstall_dry_run_out="$(python3 "${GUARD_PACKS_HELPER}" uninstall safe-bash --target claude-code --home "${audit_ready_home}" --dry-run)"
assert_contains "${uninstall_dry_run_out}" "DRY-RUN: uninstall guard pack safe-bash" "uninstall supports dry-run"
assert_cmd "uninstall dry-run keeps receipt file" test -f "${audit_ready_home}/.vibeguard/guard-packs/safe-bash/claude-code/receipt.json"
uninstall_out="$(python3 "${GUARD_PACKS_HELPER}" uninstall safe-bash --target claude-code --home "${audit_ready_home}")"
assert_contains "${uninstall_out}" "UNINSTALLED: guard pack safe-bash receipt removed" "uninstall removes receipt"
assert_cmd_fail "uninstall removes receipt file" test -e "${audit_ready_home}/.vibeguard/guard-packs/safe-bash/claude-code/receipt.json"
assert_cmd_fail "second uninstall rejects missing receipt" python3 "${GUARD_PACKS_HELPER}" uninstall safe-bash --target claude-code --home "${audit_ready_home}"

receipt_write_blocked_home="${TMP_DIR}/receipt-write-blocked-home"
mkdir -p \
  "${receipt_write_blocked_home}/.vibeguard/installed/bin" \
  "${receipt_write_blocked_home}/.vibeguard/installed/hooks" \
  "${receipt_write_blocked_home}/.vibeguard/guard-packs/safe-bash" \
  "${receipt_write_blocked_home}/.claude"
touch "${receipt_write_blocked_home}/.vibeguard/installed/bin/vibeguard-runtime"
chmod +x "${receipt_write_blocked_home}/.vibeguard/installed/bin/vibeguard-runtime"
touch "${receipt_write_blocked_home}/.vibeguard/installed/hooks/pre-bash-guard.sh"
touch "${receipt_write_blocked_home}/.vibeguard/run-hook.sh"
chmod +x "${receipt_write_blocked_home}/.vibeguard/run-hook.sh"
touch "${receipt_write_blocked_home}/.vibeguard/guard-packs/safe-bash/claude-code"
cat > "${receipt_write_blocked_home}/.claude/settings.json" <<JSON
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${receipt_write_blocked_home}/.vibeguard/run-hook.sh pre-bash-guard.sh"
          }
        ]
      }
    ]
  }
}
JSON
receipt_write_blocked_out="$(python3 "${GUARD_PACKS_HELPER}" install --target claude-code --pack safe-bash --home "${receipt_write_blocked_home}" 2>&1 || true)"
assert_contains "${receipt_write_blocked_out}" "ERROR: cannot write install receipt" "install reports receipt write errors without traceback"
assert_not_contains "${receipt_write_blocked_out}" "Traceback" "install write error does not print Python traceback"

codex_ready_home="${TMP_DIR}/codex-ready-home"
mkdir -p \
  "${codex_ready_home}/.vibeguard/installed/bin" \
  "${codex_ready_home}/.vibeguard/installed/hooks" \
  "${codex_ready_home}/.codex"
touch "${codex_ready_home}/.vibeguard/installed/bin/vibeguard-runtime"
chmod +x "${codex_ready_home}/.vibeguard/installed/bin/vibeguard-runtime"
touch "${codex_ready_home}/.vibeguard/installed/hooks/pre-bash-guard.sh"
touch "${codex_ready_home}/.vibeguard/run-hook-codex.sh"
chmod +x "${codex_ready_home}/.vibeguard/run-hook-codex.sh"
cat > "${codex_ready_home}/.codex/hooks.json" <<JSON
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${codex_ready_home}/.vibeguard/run-hook-codex.sh vibeguard-pre-bash-guard.sh"
          }
        ]
      }
    ],
    "PermissionRequest": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${codex_ready_home}/.vibeguard/run-hook-codex.sh vibeguard-pre-bash-guard.sh"
          }
        ]
      }
    ]
  }
}
JSON
cat > "${codex_ready_home}/.codex/config.toml" <<'TOML'
[features]
hooks = true
TOML
codex_audit_json="$(python3 "${GUARD_PACKS_HELPER}" audit safe-bash --target codex --home "${codex_ready_home}" --json)"
assert_contains "${codex_audit_json}" '"status": "READY"' "Codex audit JSON reports ready"
assert_contains "${codex_audit_json}" '"id": "codex-hooks-feature"' "Codex audit checks hooks feature"

codex_external_wrapper_home="${TMP_DIR}/codex-external-wrapper-home"
external_codex_wrapper="${TMP_DIR}/outside/run-hook-codex.sh"
mkdir -p \
  "${codex_external_wrapper_home}/.vibeguard/installed/bin" \
  "${codex_external_wrapper_home}/.vibeguard/installed/hooks" \
  "${codex_external_wrapper_home}/.codex" \
  "$(dirname "${external_codex_wrapper}")"
touch "${codex_external_wrapper_home}/.vibeguard/installed/bin/vibeguard-runtime"
chmod +x "${codex_external_wrapper_home}/.vibeguard/installed/bin/vibeguard-runtime"
touch "${codex_external_wrapper_home}/.vibeguard/installed/hooks/pre-bash-guard.sh"
touch "${codex_external_wrapper_home}/.vibeguard/run-hook-codex.sh" "${external_codex_wrapper}"
chmod +x "${codex_external_wrapper_home}/.vibeguard/run-hook-codex.sh" "${external_codex_wrapper}"
cat > "${codex_external_wrapper_home}/.codex/hooks.json" <<JSON
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${external_codex_wrapper} vibeguard-pre-bash-guard.sh"
          }
        ]
      }
    ],
    "PermissionRequest": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${external_codex_wrapper} vibeguard-pre-bash-guard.sh"
          }
        ]
      }
    ]
  }
}
JSON
cat > "${codex_external_wrapper_home}/.codex/config.toml" <<'TOML'
[features]
hooks = true
TOML
codex_external_wrapper_out="$(python3 "${GUARD_PACKS_HELPER}" audit safe-bash --target codex --home "${codex_external_wrapper_home}" 2>&1 || true)"
assert_contains "${codex_external_wrapper_out}" "Status: INCOMPLETE" "Codex audit rejects same-name wrapper outside VibeGuard home"
assert_contains "${codex_external_wrapper_out}" "MISSING codex-pre-bash-config" "Codex audit reports external pre hook as missing"
assert_contains "${codex_external_wrapper_out}" "MISSING codex-permission-bash-config" "Codex audit reports external permission hook as missing"
assert_cmd_fail "Codex audit exits non-zero for external wrapper command" python3 "${GUARD_PACKS_HELPER}" audit safe-bash --target codex --home "${codex_external_wrapper_home}"

codex_direct_hook_home="${TMP_DIR}/codex-direct-hook-home"
mkdir -p \
  "${codex_direct_hook_home}/.vibeguard/installed/bin" \
  "${codex_direct_hook_home}/.vibeguard/installed/hooks" \
  "${codex_direct_hook_home}/.codex"
touch "${codex_direct_hook_home}/.vibeguard/installed/bin/vibeguard-runtime"
chmod +x "${codex_direct_hook_home}/.vibeguard/installed/bin/vibeguard-runtime"
touch "${codex_direct_hook_home}/.vibeguard/installed/hooks/pre-bash-guard.sh"
touch "${codex_direct_hook_home}/.vibeguard/installed/hooks/vibeguard-pre-bash-guard.sh"
touch "${codex_direct_hook_home}/.vibeguard/run-hook-codex.sh"
chmod +x "${codex_direct_hook_home}/.vibeguard/run-hook-codex.sh"
cat > "${codex_direct_hook_home}/.codex/hooks.json" <<JSON
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${codex_direct_hook_home}/.vibeguard/installed/hooks/vibeguard-pre-bash-guard.sh"
          }
        ]
      }
    ],
    "PermissionRequest": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${codex_direct_hook_home}/.vibeguard/installed/hooks/vibeguard-pre-bash-guard.sh"
          }
        ]
      }
    ]
  }
}
JSON
cat > "${codex_direct_hook_home}/.codex/config.toml" <<'TOML'
[features]
hooks = true
TOML
codex_direct_hook_out="$(python3 "${GUARD_PACKS_HELPER}" audit safe-bash --target codex --home "${codex_direct_hook_home}" 2>&1 || true)"
assert_contains "${codex_direct_hook_out}" "Status: INCOMPLETE" "Codex audit rejects direct hook script without wrapper"
assert_contains "${codex_direct_hook_out}" "MISSING codex-pre-bash-config" "Codex audit requires pre-bash wrapper command"
assert_contains "${codex_direct_hook_out}" "MISSING codex-permission-bash-config" "Codex audit requires permission wrapper command"
assert_cmd_fail "Codex audit exits non-zero for direct hook script" python3 "${GUARD_PACKS_HELPER}" audit safe-bash --target codex --home "${codex_direct_hook_home}"

mkdir -p "${codex_ready_home}/.claude"
touch "${codex_ready_home}/.vibeguard/run-hook.sh"
chmod +x "${codex_ready_home}/.vibeguard/run-hook.sh"
cat > "${codex_ready_home}/.claude/settings.json" <<JSON
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${codex_ready_home}/.vibeguard/run-hook.sh pre-bash-guard.sh"
          }
        ]
      }
    ]
  }
}
JSON
python3 "${GUARD_PACKS_HELPER}" install --target claude-code --pack safe-bash --home "${codex_ready_home}" >/dev/null
python3 "${GUARD_PACKS_HELPER}" install --target codex --pack safe-bash --home "${codex_ready_home}" >/dev/null
assert_cmd "Claude and Codex receipts use distinct target paths" bash -c "test -f '${codex_ready_home}/.vibeguard/guard-packs/safe-bash/claude-code/receipt.json' && test -f '${codex_ready_home}/.vibeguard/guard-packs/safe-bash/codex/receipt.json'"
assert_cmd "target-scoped receipts preserve target values" python3 -c '
import json
from pathlib import Path
home = Path("'"${codex_ready_home}"'")
claude = json.loads((home / ".vibeguard/guard-packs/safe-bash/claude-code/receipt.json").read_text())
codex = json.loads((home / ".vibeguard/guard-packs/safe-bash/codex/receipt.json").read_text())
assert claude["target"] == "claude-code"
assert codex["target"] == "codex"
'
python3 "${GUARD_PACKS_HELPER}" uninstall safe-bash --target claude-code --home "${codex_ready_home}" >/dev/null
assert_cmd "uninstalling one target keeps the other target receipt" test -f "${codex_ready_home}/.vibeguard/guard-packs/safe-bash/codex/receipt.json"
python3 "${GUARD_PACKS_HELPER}" uninstall safe-bash --target codex --home "${codex_ready_home}" >/dev/null

header "demo"
safe_bash_demo_out="$(python3 "${GUARD_PACKS_HELPER}" demo safe-bash)"
assert_contains "${safe_bash_demo_out}" "No command is executed" "safe-bash demo is side-effect free"
assert_contains "${safe_bash_demo_out}" "Expected decision: block" "safe-bash demo shows block decision"

header "setup routes"
setup_packs_out="$(bash "${REPO_DIR}/setup.sh" packs list)"
assert_contains "${setup_packs_out}" "safe-bash" "setup packs route lists safe-bash"
setup_pack_explain_out="$(bash "${REPO_DIR}/setup.sh" packs explain safe-bash)"
assert_contains "${setup_pack_explain_out}" "Guard Packs are an adoption layer" "setup packs explain uses guard pack helper"
setup_pack_receipt_out="$(bash "${REPO_DIR}/setup.sh" packs receipt safe-bash --target claude-code)"
assert_contains "${setup_pack_receipt_out}" '"receipt_path": "~/.vibeguard/guard-packs/safe-bash/claude-code/receipt.json"' "setup packs receipt route works"
setup_pack_audit_out="$(bash "${REPO_DIR}/setup.sh" packs audit safe-bash --target claude-code --home "${audit_ready_home}")"
assert_contains "${setup_pack_audit_out}" "Status: READY" "setup packs audit route works"
setup_pack_install_out="$(bash "${REPO_DIR}/setup.sh" install --target claude-code --pack safe-bash --dry-run)"
assert_contains "${setup_pack_install_out}" "DRY-RUN: install guard pack safe-bash for claude-code" "setup install --pack routes to guard pack dry-run"
setup_pack_equals_out="$(bash "${REPO_DIR}/setup.sh" install --target=claude-code --pack=safe-bash --dry-run)"
assert_contains "${setup_pack_equals_out}" "DRY-RUN: install guard pack safe-bash for claude-code" "setup install --pack= routes to guard pack dry-run"
setup_pack_install_live_out="$(bash "${REPO_DIR}/setup.sh" install --target claude-code --pack safe-bash --home "${audit_ready_home}")"
assert_contains "${setup_pack_install_live_out}" "INSTALLED: guard pack safe-bash registered for claude-code" "setup install --pack registers receipt"
setup_pack_uninstall_out="$(bash "${REPO_DIR}/setup.sh" packs uninstall safe-bash --target claude-code --home "${audit_ready_home}")"
assert_contains "${setup_pack_uninstall_out}" "UNINSTALLED: guard pack safe-bash receipt removed" "setup packs uninstall removes receipt"
setup_pack_demo_out="$(bash "${REPO_DIR}/setup.sh" demo safe-bash)"
assert_contains "${setup_pack_demo_out}" "No command is executed" "setup demo route is side-effect free"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

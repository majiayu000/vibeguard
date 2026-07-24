#!/usr/bin/env bash
# VibeGuard Codex runtime regression tests
#
# Usage: bash tests/test_codex_runtime.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

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

assert_codex_pretool_output_contract() {
  local output="$1" desc="$2"
  TOTAL=$((TOTAL + 1))
  if printf '%s' "${output}" | python3 -c '
import json
import sys

try:
    data = json.loads(sys.stdin.read())
except Exception as exc:
    print(f"invalid JSON: {exc}", file=sys.stderr)
    raise SystemExit(1)

allowed_top = {
    "continue",
    "stopReason",
    "suppressOutput",
    "systemMessage",
    "decision",
    "reason",
    "hookSpecificOutput",
}
extra_top = sorted(set(data) - allowed_top)
if extra_top:
    print(f"unknown top-level fields: {extra_top}", file=sys.stderr)
    raise SystemExit(1)
if data.get("continue", True) is not True:
    print("Codex PreToolUse does not support continue:false", file=sys.stderr)
    raise SystemExit(1)
if "stopReason" in data:
    print("Codex PreToolUse does not support stopReason", file=sys.stderr)
    raise SystemExit(1)
if data.get("suppressOutput", False):
    print("Codex PreToolUse does not support suppressOutput:true", file=sys.stderr)
    raise SystemExit(1)

decision = data.get("decision")
if decision == "block":
    if not str(data.get("reason", "")).strip():
        print("Codex PreToolUse decision:block requires a non-empty reason", file=sys.stderr)
        raise SystemExit(1)
elif decision is not None:
    print(f"unsupported VibeGuard PreToolUse top-level decision: {decision}", file=sys.stderr)
    raise SystemExit(1)
elif "reason" in data:
    print("Codex PreToolUse reason requires decision:block", file=sys.stderr)
    raise SystemExit(1)

specific = data.get("hookSpecificOutput")
if specific is None:
    raise SystemExit(0)
if not isinstance(specific, dict):
    print("hookSpecificOutput must be an object", file=sys.stderr)
    raise SystemExit(1)

allowed_specific = {
    "hookEventName",
    "permissionDecision",
    "permissionDecisionReason",
    "updatedInput",
    "additionalContext",
}
extra_specific = sorted(set(specific) - allowed_specific)
if extra_specific:
    print(f"unknown PreToolUse hookSpecificOutput fields: {extra_specific}", file=sys.stderr)
    raise SystemExit(1)
if specific.get("hookEventName") != "PreToolUse":
    print("hookSpecificOutput.hookEventName must be PreToolUse", file=sys.stderr)
    raise SystemExit(1)

permission_decision = specific.get("permissionDecision")
if permission_decision == "deny":
    if not str(specific.get("permissionDecisionReason", "")).strip():
        print("permissionDecision:deny requires permissionDecisionReason", file=sys.stderr)
        raise SystemExit(1)
elif permission_decision is not None:
    print(f"unsupported VibeGuard PreToolUse permissionDecision: {permission_decision}", file=sys.stderr)
    raise SystemExit(1)
elif "permissionDecisionReason" in specific:
    print("permissionDecisionReason requires permissionDecision", file=sys.stderr)
    raise SystemExit(1)
if "updatedInput" in specific:
    print("VibeGuard Codex wrapper must not emit updatedInput on native PreToolUse", file=sys.stderr)
    raise SystemExit(1)
'
  then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc"
    FAIL=$((FAIL + 1))
  fi
}

assert_codex_posttool_output_contract() {
  local output="$1" desc="$2"
  TOTAL=$((TOTAL + 1))
  if printf '%s' "${output}" | python3 -c '
import json
import sys

try:
    data = json.loads(sys.stdin.read())
except Exception as exc:
    print(f"invalid JSON: {exc}", file=sys.stderr)
    raise SystemExit(1)

allowed_top = {
    "continue",
    "stopReason",
    "suppressOutput",
    "systemMessage",
    "decision",
    "reason",
    "hookSpecificOutput",
}
extra_top = sorted(set(data) - allowed_top)
if extra_top:
    print(f"unknown top-level fields: {extra_top}", file=sys.stderr)
    raise SystemExit(1)
if data.get("suppressOutput", False):
    print("Codex PostToolUse does not support suppressOutput:true", file=sys.stderr)
    raise SystemExit(1)

decision = data.get("decision")
if decision == "block":
    if not str(data.get("reason", "")).strip():
        print("Codex PostToolUse decision:block requires a non-empty reason", file=sys.stderr)
        raise SystemExit(1)
elif decision is not None:
    print(f"unsupported VibeGuard PostToolUse decision: {decision}", file=sys.stderr)
    raise SystemExit(1)
elif "reason" in data:
    print("Codex PostToolUse reason requires decision:block", file=sys.stderr)
    raise SystemExit(1)

specific = data.get("hookSpecificOutput")
if specific is None:
    raise SystemExit(0)
if not isinstance(specific, dict):
    print("hookSpecificOutput must be an object", file=sys.stderr)
    raise SystemExit(1)
allowed_specific = {"hookEventName", "additionalContext", "updatedMCPToolOutput"}
extra_specific = sorted(set(specific) - allowed_specific)
if extra_specific:
    print(f"unknown PostToolUse hookSpecificOutput fields: {extra_specific}", file=sys.stderr)
    raise SystemExit(1)
if specific.get("hookEventName") != "PostToolUse":
    print("hookSpecificOutput.hookEventName must be PostToolUse", file=sys.stderr)
    raise SystemExit(1)
if "updatedMCPToolOutput" in specific:
    print("VibeGuard Codex wrapper must not emit updatedMCPToolOutput", file=sys.stderr)
    raise SystemExit(1)
'
  then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

export VIBEGUARD_EXECUTION_MODE=dev-linked-repo


for codex_runtime_test in \
  "${REPO_DIR}/tests/codex_runtime/protocol_helper_tests.sh" \
  "${REPO_DIR}/tests/codex_runtime/hook_name_resolution_tests.sh" \
  "${REPO_DIR}/tests/codex_runtime/pretool_diagnostic_tests.sh" \
  "${REPO_DIR}/tests/codex_runtime/posttool_large_io_tests.sh" \
  "${REPO_DIR}/tests/codex_runtime/native_permission_patch_tests.sh" \
  "${REPO_DIR}/tests/codex_runtime/app_server_wrapper_tests.sh" \
  "${REPO_DIR}/tests/codex_runtime/session_identity_tests.sh"; do
  # shellcheck source=/dev/null
  source "${codex_runtime_test}"
done

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

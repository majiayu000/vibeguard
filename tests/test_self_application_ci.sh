#!/usr/bin/env bash
# VibeGuard self-application CI regression tests
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SELF_DIR="${REPO_DIR}/scripts/ci/self-application"

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

assert_fails() {
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

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

header "self-application scripts"
assert_cmd "all self-application scripts have valid syntax" bash -n "${SELF_DIR}"/*.sh
assert_cmd "self-application run-all passes on this repository" bash "${SELF_DIR}/run-all.sh" "${REPO_DIR}"

header "hook output rewriting sentinel"
bad_root="${TMP_DIR}/bad-output-rewrite"
mkdir -p "${bad_root}/hooks" "${bad_root}/scripts"
cat > "${bad_root}/hooks/bad.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"updatedToolOutput":"rewritten without a reason"}'
EOF
assert_fails "updatedToolOutput without SEC-13 reason fails" bash "${SELF_DIR}/check-hook-output-rewriting.sh" "${bad_root}"

good_root="${TMP_DIR}/good-output-rewrite"
mkdir -p "${good_root}/hooks" "${good_root}/scripts"
cat > "${good_root}/hooks/good.sh" <<'EOF'
#!/usr/bin/env bash
# SEC-13-OUTPUT-REWRITE-REASON: test fixture explains the rewrite.
echo '{"updatedToolOutput":"rewritten with a reason"}'
EOF
assert_cmd "updatedToolOutput with SEC-13 reason passes" bash "${SELF_DIR}/check-hook-output-rewriting.sh" "${good_root}"

header "U-29 sentinel"
bad_u29="${TMP_DIR}/bad-u29"
mkdir -p "${bad_u29}/scripts" "${bad_u29}/hooks" "${bad_u29}/eval"
cat > "${bad_u29}/scripts/bad.py" <<'PY'
try:
    risky()
except Exception:
    pass
PY
cat > "${bad_u29}/hooks/pre-commit-guard.sh" <<'EOF'
code=124; [[ $code -eq 124 ]] && return 0
EOF
cat > "${bad_u29}/hooks/pre-bash-guard.sh" <<'EOF'
COMMAND=$(vg_json_field "tool_input.command")
EOF
cat > "${bad_u29}/eval/run_eval.py" <<'PY'
def x():
    return {"detected": False}
PY
assert_fails "silent Exception pass fails U-29 check" bash "${SELF_DIR}/check-u29-no-silent-degrade.sh" "${bad_u29}"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

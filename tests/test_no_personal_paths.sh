#!/usr/bin/env bash
# Regression tests for validate-no-personal-paths.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATOR="${REPO_DIR}/scripts/ci/validate-no-personal-paths.sh"

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

assert_fails_with() {
  local desc="$1" expected="$2"
  shift 2
  TOTAL=$((TOTAL + 1))
  local output
  if output="$("$@" 2>&1)"; then
    red "$desc (expected failure)"
    FAIL=$((FAIL + 1))
  elif echo "$output" | grep -qF -- "$expected"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected output to contain: $expected)"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

header "syntax"
assert_cmd "validate-no-personal-paths.sh syntax is valid" bash -n "${VALIDATOR}"

header "worktree gitfile"
FAKE_REPO="${TMP_DIR}/repo"
mkdir -p "${FAKE_REPO}/scripts/ci"
cp "${VALIDATOR}" "${FAKE_REPO}/scripts/ci/validate-no-personal-paths.sh"
chmod +x "${FAKE_REPO}/scripts/ci/validate-no-personal-paths.sh"
printf 'gitdir: /Users/alice/project/.git/worktrees/repo\n' > "${FAKE_REPO}/.git"
assert_cmd "linked-worktree .git file is ignored" bash "${FAKE_REPO}/scripts/ci/validate-no-personal-paths.sh"

header "local agent state"
mkdir -p "${FAKE_REPO}/.omx/state"
printf '{"path": "/Users/alice/project/cache"}\n' > "${FAKE_REPO}/.omx/state/local.json"
assert_cmd "ignored local .omx state is not scanned" bash "${FAKE_REPO}/scripts/ci/validate-no-personal-paths.sh"

header "real source leak"
printf 'command: /Users/alice/project/run.sh\n' > "${FAKE_REPO}/leak.txt"
assert_fails_with "ordinary file with personal path still fails" "leak.txt" \
  bash "${FAKE_REPO}/scripts/ci/validate-no-personal-paths.sh"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

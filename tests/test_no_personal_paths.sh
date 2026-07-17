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
  elif grep -qF -- "$expected" <<< "$output"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected output to contain: $expected)"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR="$(mktemp -d)"
cleanup() {
  git -C "${BASE_REPO:-$TMP_DIR}" worktree remove --force "${FAKE_REPO:-$TMP_DIR/missing}" >/dev/null 2>&1 || true
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

header "syntax"
assert_cmd "validate-no-personal-paths.sh syntax is valid" bash -n "${VALIDATOR}"

header "tracked boundary"
BASE_REPO="${TMP_DIR}/base"
FAKE_REPO="${TMP_DIR}/repo"
mkdir -p "${BASE_REPO}/scripts/ci"
cp "${VALIDATOR}" "${BASE_REPO}/scripts/ci/validate-no-personal-paths.sh"
chmod +x "${BASE_REPO}/scripts/ci/validate-no-personal-paths.sh"
git -C "${BASE_REPO}" init -q
git -C "${BASE_REPO}" add scripts/ci/validate-no-personal-paths.sh
git -C "${BASE_REPO}" -c user.name=test -c user.email=test@example.com commit -qm init
git -C "${BASE_REPO}" worktree add -q "${FAKE_REPO}"
assert_cmd "linked worktree gitfile is outside tracked input" \
  bash "${FAKE_REPO}/scripts/ci/validate-no-personal-paths.sh"

mkdir -p "${FAKE_REPO}/artifacts"
printf 'path: /Users/%s/untracked\n' alice > "${FAKE_REPO}/artifacts/local.md"
assert_cmd "untracked artifact does not affect the result" \
  bash "${FAKE_REPO}/scripts/ci/validate-no-personal-paths.sh"

header "tracked markdown classification"
printf 'run: /Users/%s/project/run.sh\n' alice > "${FAKE_REPO}/leak.md"
git -C "${FAKE_REPO}" add leak.md
assert_fails_with "tracked Markdown literal user fails" "leak.md:1: hardcoded_personal_path" \
  bash "${FAKE_REPO}/scripts/ci/validate-no-personal-paths.sh"

printf 'run: /home/%s/project/run.sh\n' bob > "${FAKE_REPO}/home-leak.md"
git -C "${FAKE_REPO}" add home-leak.md
assert_fails_with "tracked Markdown home literal user fails" "home-leak.md:1: hardcoded_personal_path" \
  bash "${FAKE_REPO}/scripts/ci/validate-no-personal-paths.sh"

printf 'run: /Users/%s/project/run.sh\n' carol > "${FAKE_REPO}/source.txt"
git -C "${FAKE_REPO}" add source.txt
assert_fails_with "tracked non-Markdown literal user fails" "source.txt:1: hardcoded_personal_path" \
  bash "${FAKE_REPO}/scripts/ci/validate-no-personal-paths.sh"

git -C "${FAKE_REPO}" rm -q --cached leak.md home-leak.md source.txt
rm "${FAKE_REPO}/leak.md" "${FAKE_REPO}/home-leak.md" "${FAKE_REPO}/source.txt"
cat > "${FAKE_REPO}/placeholder.md" <<'MD'
run: /Users/<username>/project/run.sh
run: /home/<user>/project/run.sh
run: /Users/$USER/project/run.sh
MD
git -C "${FAKE_REPO}" add placeholder.md
assert_cmd "explicit Markdown placeholders pass" \
  bash "${FAKE_REPO}/scripts/ci/validate-no-personal-paths.sh"

header "fail-visible input errors"
printf 'tracked then removed\n' > "${FAKE_REPO}/missing.txt"
git -C "${FAKE_REPO}" add missing.txt
rm "${FAKE_REPO}/missing.txt"
assert_fails_with "missing tracked file fails visibly" "missing.txt: scan_error" \
  bash "${FAKE_REPO}/scripts/ci/validate-no-personal-paths.sh"

NON_GIT_REPO="${TMP_DIR}/not-git"
mkdir -p "${NON_GIT_REPO}/scripts/ci"
cp "${VALIDATOR}" "${NON_GIT_REPO}/scripts/ci/validate-no-personal-paths.sh"
assert_fails_with "Git enumeration failure is not an empty success" "scan_error: git ls-files failed" \
  bash "${NON_GIT_REPO}/scripts/ci/validate-no-personal-paths.sh"

header "determinism"
git -C "${FAKE_REPO}" reset -q -- missing.txt
first_out="$(bash "${FAKE_REPO}/scripts/ci/validate-no-personal-paths.sh")"
second_out="$(bash "${FAKE_REPO}/scripts/ci/validate-no-personal-paths.sh")"
TOTAL=$((TOTAL + 1))
if [[ "${first_out}" == "${second_out}" ]]; then
  green "same tracked tree produces identical output"
  PASS=$((PASS + 1))
else
  red "same tracked tree produces identical output"
  FAIL=$((FAIL + 1))
fi

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

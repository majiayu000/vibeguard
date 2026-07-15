#!/usr/bin/env bash
# Deterministic contract tests for the U-22 measured Rust coverage gate.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="${REPO_DIR}/scripts/ci/self-application/check-u22-coverage.sh"

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }

assert_cmd() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc"
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

FAKE_CARGO="${TMP_DIR}/cargo"
CALL_LOG="${TMP_DIR}/calls.log"
cat > "${FAKE_CARGO}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${VIBEGUARD_U22_TEST_CALL_LOG}"
if [[ "${1:-}" == "llvm-cov" && "${2:-}" == "--version" ]]; then
  printf 'cargo-llvm-cov %s\n' "${VIBEGUARD_U22_TEST_VERSION:-0.8.7}"
  exit "${VIBEGUARD_U22_TEST_VERSION_STATUS:-0}"
fi
exit "${VIBEGUARD_U22_TEST_COVERAGE_STATUS:-0}"
SH
chmod +x "${FAKE_CARGO}"

run_gate() {
  env \
    VIBEGUARD_U22_CARGO_BIN="${FAKE_CARGO}" \
    VIBEGUARD_U22_TEST_CALL_LOG="${CALL_LOG}" \
    "$@"
}

success_out="$(run_gate bash "${CHECK}" "${REPO_DIR}")"
assert_cmd "coverage gate accepts a successful measured run" test -n "${success_out}"
assert_cmd "coverage output names the 68% blocking baseline" grep -Fq "blocking baseline=68%" <<< "${success_out}"
assert_cmd "coverage output keeps the 80% target visible" grep -Fq "target=80% (target not yet enforced)" <<< "${success_out}"
assert_cmd "coverage command uses the locked runtime manifest" grep -Fq \
  "llvm-cov --locked --manifest-path ${REPO_DIR}/vibeguard-runtime/Cargo.toml --summary-only --fail-under-lines 68" \
  "${CALL_LOG}"

assert_fails "missing cargo-llvm-cov fails closed" env \
  VIBEGUARD_U22_CARGO_BIN="${TMP_DIR}/missing-cargo" \
  bash "${CHECK}" "${REPO_DIR}"
assert_fails "unexpected cargo-llvm-cov version fails closed" env \
  VIBEGUARD_U22_CARGO_BIN="${FAKE_CARGO}" \
  VIBEGUARD_U22_TEST_CALL_LOG="${CALL_LOG}" \
  VIBEGUARD_U22_TEST_VERSION="0.8.6" \
  bash "${CHECK}" "${REPO_DIR}"
assert_fails "coverage regression exit status fails closed" env \
  VIBEGUARD_U22_CARGO_BIN="${FAKE_CARGO}" \
  VIBEGUARD_U22_TEST_CALL_LOG="${CALL_LOG}" \
  VIBEGUARD_U22_TEST_COVERAGE_STATUS="9" \
  bash "${CHECK}" "${REPO_DIR}"
assert_fails "missing runtime manifest fails closed" run_gate bash "${CHECK}" "${TMP_DIR}/missing-repo"

printf '\n==============================\n'
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' "${TOTAL}" "${PASS}" "${FAIL}"
printf '==============================\n'

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi

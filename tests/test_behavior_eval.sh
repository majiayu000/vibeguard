#!/usr/bin/env bash
# VibeGuard behavior eval regression tests

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

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

header "behavior eval syntax and unit tests"
assert_cmd "behavior eval runner compiles" python3 -m py_compile "${REPO_DIR}/eval/run_behavior_eval.py"
assert_cmd "behavior eval unit tests pass" python3 "${REPO_DIR}/eval/test_behavior_eval.py"

header "runtime-backed behavior paths"
if [[ ! -x "${REPO_DIR}/vibeguard-runtime/target/release/vibeguard-runtime" ]]; then
  assert_cmd "release vibeguard-runtime builds for hook behavior evals" \
    cargo build --release --manifest-path "${REPO_DIR}/vibeguard-runtime/Cargo.toml" --quiet
fi

behavior_out="$(
  cd "${REPO_DIR}" && python3 eval/run_behavior_eval.py \
    --fail-on-threshold \
    --artifact-root "${TMP_DIR}/runs"
)"
assert_contains "${behavior_out}" "Behavior gate: pass" "default behavior gate passes thresholds"
assert_contains "${behavior_out}" "claude=7/7" "behavior report includes Claude platform slice"
assert_contains "${behavior_out}" "codex=7/7" "behavior report includes Codex platform slice"
assert_contains "${behavior_out}" "Result saved:" "behavior eval writes immutable run artifact"
assert_cmd "behavior eval writes summary index" test -s "${TMP_DIR}/runs/index.jsonl"
assert_contains "$(cat "${TMP_DIR}/runs/index.jsonl")" '"kind": "behavior"' "behavior index records summary kind"

summary_out="$(cd "${REPO_DIR}" && python3 eval/summarize_runs.py --runs-dir "${TMP_DIR}/runs" --last 1)"
assert_contains "${summary_out}" "deterministic" "summary reader labels behavior scores deterministic"
assert_contains "${summary_out}" "verdict=pass" "summary reader displays behavior verdict"
assert_contains "${summary_out}" "pass=100.0%" "summary reader displays behavior pass rate"
assert_contains "${summary_out}" "failures=0" "summary reader displays behavior failure count"

header "missing coverage is insufficient evidence"
missing_requirements="${TMP_DIR}/requirements.json"
cat > "${missing_requirements}" <<'JSON'
[
  {"platform": "claude", "hook": "pre-bash-guard"},
  {"platform": "codex", "hook": "stop-guard"}
]
JSON

set +e
missing_out="$(
  cd "${REPO_DIR}" && python3 eval/run_behavior_eval.py \
    --json \
    --fail-on-threshold \
    --requirements "${missing_requirements}" \
    --artifact-root "${TMP_DIR}/missing-runs"
)"
missing_rc=$?
set -e

TOTAL=$((TOTAL + 1))
if [[ ${missing_rc} -ne 0 ]]; then
  green "missing required behavior coverage fails the threshold gate"
  PASS=$((PASS + 1))
else
  red "missing required behavior coverage fails the threshold gate"
  FAIL=$((FAIL + 1))
fi
assert_contains "${missing_out}" '"verdict": "fail"' "missing coverage is visible in JSON report"
assert_contains "${missing_out}" '"hook": "stop-guard"' "missing coverage names the absent hook"
assert_contains "${missing_out}" '"score": 50.0' "missing coverage reduces the behavior score"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

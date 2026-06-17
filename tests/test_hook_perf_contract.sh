#!/usr/bin/env bash
# Regression tests for the hook latency/performance contract.
#
# Usage: bash tests/test_hook_perf_contract.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATOR="${REPO_DIR}/scripts/ci/validate-hook-perf.sh"
BENCH="${REPO_DIR}/tests/bench_hook_latency.sh"
BENCHMARK="${REPO_DIR}/scripts/benchmark.sh"
THRESHOLD_VALIDATOR="${REPO_DIR}/scripts/ci/validate-precision-thresholds.sh"

PASS=0
FAIL=0
TOTAL=0
TMP_DIR="$(mktemp -d)"
BENCH_JSON_FILE="${REPO_DIR}/data/bench-latency-$(date +%Y%m%d).json"
BENCH_JSON_TEMP="${TMP_DIR}/bench-latency.json"
BENCH_ACTION_TEMP="${TMP_DIR}/bench-output.json"
ROOT_BENCH_ACTION_FILE="${REPO_DIR}/bench-output.json"
BENCH_JSON_EXISTED=false
BENCH_JSON_BACKUP="${TMP_DIR}/bench-latency-existing.json"
if [[ -e "${BENCH_JSON_FILE}" ]]; then
  BENCH_JSON_EXISTED=true
  cp "${BENCH_JSON_FILE}" "${BENCH_JSON_BACKUP}"
fi
ROOT_BENCH_ACTION_EXISTED=false
ROOT_BENCH_ACTION_BACKUP="${TMP_DIR}/bench-output-existing.json"
if [[ -e "${ROOT_BENCH_ACTION_FILE}" ]]; then
  ROOT_BENCH_ACTION_EXISTED=true
  cp "${ROOT_BENCH_ACTION_FILE}" "${ROOT_BENCH_ACTION_BACKUP}"
  rm -f "${ROOT_BENCH_ACTION_FILE}"
fi

cleanup() {
  if [[ "${BENCH_JSON_EXISTED}" == "true" ]]; then
    cp "${BENCH_JSON_BACKUP}" "${BENCH_JSON_FILE}" 2>/dev/null || true
  else
    rm -f "${BENCH_JSON_FILE}"
  fi
  if [[ "${ROOT_BENCH_ACTION_EXISTED}" == "true" ]]; then
    cp "${ROOT_BENCH_ACTION_BACKUP}" "${ROOT_BENCH_ACTION_FILE}" 2>/dev/null || true
  else
    rm -f "${ROOT_BENCH_ACTION_FILE}"
  fi
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
    red "$desc"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_contains() {
  local file="$1"
  local expected="$2"
  local desc="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qF -- "$expected" "$file"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected: $expected)"
    FAIL=$((FAIL + 1))
  fi
}

assert_fail_contains() {
  local desc="$1"
  local expected="$2"
  local output_file="$3"
  shift 3
  TOTAL=$((TOTAL + 1))
  "$@" >"${output_file}" 2>&1
  local exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qF -- "$expected" "${output_file}"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (exit=${exit_code}, expected output: $expected)"
    FAIL=$((FAIL + 1))
  fi
}

assert_success_contains() {
  local desc="$1"
  local expected="$2"
  local output_file="$3"
  shift 3
  TOTAL=$((TOTAL + 1))
  "$@" >"${output_file}" 2>&1
  local exit_code=$?
  if [[ "$exit_code" -eq 0 ]] && grep -qF -- "$expected" "${output_file}"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (exit=${exit_code}, expected output: $expected)"
    FAIL=$((FAIL + 1))
  fi
}

write_hook() {
  local dir="$1"
  local name="$2"
  local body="$3"
  mkdir -p "$dir"
  printf '%s\n' '#!/usr/bin/env bash' "$body" > "${dir}/${name}"
  chmod +x "${dir}/${name}"
}

header "syntax"
assert_cmd "performance validator syntax" bash -n "${VALIDATOR}"
assert_cmd "latency benchmark syntax" bash -n "${BENCH}"
assert_cmd "benchmark syntax" bash -n "${BENCHMARK}"
assert_cmd "precision threshold validator syntax" bash -n "${THRESHOLD_VALIDATOR}"
assert_file_contains "${BENCH}" "Codex wrapper benchmark requires vibeguard-runtime" "latency benchmark fails fast without runtime for Codex wrapper fixtures"

header "static performance gates"
GOOD_HOOKS="${TMP_DIR}/good-hooks"
write_hook "${GOOD_HOOKS}" "good-hook.sh" 'find "$PROJECT_DIR" -maxdepth 1 -type f >/dev/null 2>&1 || true'
assert_cmd "bounded find passes static validator" env VIBEGUARD_HOOKS_DIR="${GOOD_HOOKS}" bash "${VALIDATOR}"

MULTILINE_HOOKS="${TMP_DIR}/multiline-hooks"
write_hook "${MULTILINE_HOOKS}" "multiline-hook.sh" 'find "$PROJECT_DIR" \
  -maxdepth 1 \
  -type f >/dev/null 2>&1 || true'
assert_cmd "multiline bounded find passes static validator" env VIBEGUARD_HOOKS_DIR="${MULTILINE_HOOKS}" bash "${VALIDATOR}"

DOCUMENTED_HOOKS="${TMP_DIR}/documented-hooks"
write_hook "${DOCUMENTED_HOOKS}" "documented-hook.sh" '# PERF-OK: fixture intentionally scans its temp project root.
find "$PROJECT_DIR" -type f >/dev/null 2>&1 || true'
assert_cmd "PERF-OK documents an intentional scan" env VIBEGUARD_HOOKS_DIR="${DOCUMENTED_HOOKS}" bash "${VALIDATOR}"

DOCUMENTED_JSONL_OPEN_HOOKS="${TMP_DIR}/documented-jsonl-open-hooks"
write_hook "${DOCUMENTED_JSONL_OPEN_HOOKS}" "documented-jsonl-open-hook.sh" 'python3 - <<PY
import os
# PERF-OK: fixture intentionally reads the full log.
with open(os.environ["VIBEGUARD_LOG_FILE"], encoding="utf-8") as handle:
    print(handle.readline())
PY'
assert_cmd "PERF-OK documents an intentional full JSONL read" env VIBEGUARD_HOOKS_DIR="${DOCUMENTED_JSONL_OPEN_HOOKS}" bash "${VALIDATOR}"

TIMEOUT_GIT_HOOKS="${TMP_DIR}/timeout-git-hooks"
write_hook "${TIMEOUT_GIT_HOOKS}" "timeout-git-hook.sh" 'gtimeout 2 git status --short >/dev/null'
assert_cmd "gtimeout-wrapped git call passes static validator" env VIBEGUARD_HOOKS_DIR="${TIMEOUT_GIT_HOOKS}" bash "${VALIDATOR}"

DOCUMENTED_GIT_HOOKS="${TMP_DIR}/documented-git-hooks"
write_hook "${DOCUMENTED_GIT_HOOKS}" "documented-git-hook.sh" '# PERF-OK: fixture intentionally exercises unbounded git for the gate.
git status --short >/dev/null'
assert_cmd "PERF-OK documents an intentional git call" env VIBEGUARD_HOOKS_DIR="${DOCUMENTED_GIT_HOOKS}" bash "${VALIDATOR}"

STRING_GIT_HOOKS="${TMP_DIR}/string-git-hooks"
write_hook "${STRING_GIT_HOOKS}" "string-git-hook.sh" 'vg_warn "Copy-paste:
  git status --short
"'
assert_cmd "git in multiline warning string does not count" env VIBEGUARD_HOOKS_DIR="${STRING_GIT_HOOKS}" bash "${VALIDATOR}"

OUTPUT_LITERAL_GIT_HOOKS="${TMP_DIR}/output-literal-git-hooks"
write_hook "${OUTPUT_LITERAL_GIT_HOOKS}" "output-literal-git-hook.sh" 'printf "%s\n" "Copy-paste: git status --short"'
assert_cmd "git in output literal does not count" env VIBEGUARD_HOOKS_DIR="${OUTPUT_LITERAL_GIT_HOOKS}" bash "${VALIDATOR}"

BAD_FIND_HOOKS="${TMP_DIR}/bad-find-hooks"
write_hook "${BAD_FIND_HOOKS}" "bad-find-hook.sh" 'find "$PROJECT_DIR" -type f >/dev/null 2>&1 || true'
assert_fail_contains "unbounded find fails static validator" "PERF-02" "${TMP_DIR}/bad-find.out" env VIBEGUARD_HOOKS_DIR="${BAD_FIND_HOOKS}" bash "${VALIDATOR}"
assert_file_contains "${TMP_DIR}/bad-find.out" "bad-find-hook.sh" "unbounded find output names the hook"

BAD_EXEC_FIND_HOOKS="${TMP_DIR}/bad-exec-find-hooks"
write_hook "${BAD_EXEC_FIND_HOOKS}/git" "pre-push" 'find "$PROJECT_DIR" -type f >/dev/null 2>&1 || true'
assert_fail_contains "unbounded find in executable hook fails static validator" "PERF-02" "${TMP_DIR}/bad-exec-find.out" env VIBEGUARD_HOOKS_DIR="${BAD_EXEC_FIND_HOOKS}" bash "${VALIDATOR}"
assert_file_contains "${TMP_DIR}/bad-exec-find.out" "pre-push" "executable find output names the hook"

BAD_JSONL_OPEN_HOOKS="${TMP_DIR}/bad-jsonl-open-hooks"
write_hook "${BAD_JSONL_OPEN_HOOKS}" "bad-jsonl-open-hook.sh" 'python3 - <<PY
log_file = "${VIBEGUARD_LOG_FILE:-events.jsonl}"
with open(log_file, encoding="utf-8") as handle:
    print(handle.readline())
PY'
assert_fail_contains "direct log_file open fails static validator" "PERF-01" "${TMP_DIR}/bad-jsonl-open.out" env VIBEGUARD_HOOKS_DIR="${BAD_JSONL_OPEN_HOOKS}" bash "${VALIDATOR}"
assert_file_contains "${TMP_DIR}/bad-jsonl-open.out" "bad-jsonl-open-hook.sh" "direct log_file open output names the hook"

BAD_LIB_JSONL_OPEN_HOOKS="${TMP_DIR}/bad-lib-jsonl-open-hooks"
write_hook "${BAD_LIB_JSONL_OPEN_HOOKS}/_lib" "bad-lib.sh" 'python3 - <<PY
import os
with open(os.environ["VIBEGUARD_LOG_FILE"], encoding="utf-8") as handle:
    print(handle.readline())
PY'
assert_fail_contains "helper log env open fails static validator" "PERF-01" "${TMP_DIR}/bad-lib-jsonl-open.out" env VIBEGUARD_HOOKS_DIR="${BAD_LIB_JSONL_OPEN_HOOKS}" bash "${VALIDATOR}"
assert_file_contains "${TMP_DIR}/bad-lib-jsonl-open.out" "bad-lib.sh" "helper log env open output names the file"

BAD_GIT_HOOKS="${TMP_DIR}/bad-git-hooks"
write_hook "${BAD_GIT_HOOKS}" "bad-git-hook.sh" 'git status --short >/dev/null'
assert_fail_contains "unsafe git call fails static validator" "PERF-03" "${TMP_DIR}/bad-git.out" env VIBEGUARD_HOOKS_DIR="${BAD_GIT_HOOKS}" bash "${VALIDATOR}"
assert_file_contains "${TMP_DIR}/bad-git.out" "bad-git-hook.sh" "unsafe git output names the hook"

BAD_ABSOLUTE_GIT_HOOKS="${TMP_DIR}/bad-absolute-git-hooks"
write_hook "${BAD_ABSOLUTE_GIT_HOOKS}" "bad-absolute-git-hook.sh" '/usr/bin/git status --short >/dev/null'
assert_fail_contains "unsafe absolute git call fails static validator" "PERF-03" "${TMP_DIR}/bad-absolute-git.out" env VIBEGUARD_HOOKS_DIR="${BAD_ABSOLUTE_GIT_HOOKS}" bash "${VALIDATOR}"
assert_file_contains "${TMP_DIR}/bad-absolute-git.out" "bad-absolute-git-hook.sh" "absolute git output names the hook"

BAD_OUTPUT_SUB_GIT_HOOKS="${TMP_DIR}/bad-output-sub-git-hooks"
write_hook "${BAD_OUTPUT_SUB_GIT_HOOKS}" "bad-output-sub-git-hook.sh" 'printf "%s\n" "$(git status --short >/dev/null)"'
assert_fail_contains "git in output command substitution fails static validator" "PERF-03" "${TMP_DIR}/bad-output-sub-git.out" env VIBEGUARD_HOOKS_DIR="${BAD_OUTPUT_SUB_GIT_HOOKS}" bash "${VALIDATOR}"
assert_file_contains "${TMP_DIR}/bad-output-sub-git.out" "bad-output-sub-git-hook.sh" "output substitution git names the hook"

BAD_OUTPUT_PROC_SUB_GIT_HOOKS="${TMP_DIR}/bad-output-proc-sub-git-hooks"
write_hook "${BAD_OUTPUT_PROC_SUB_GIT_HOOKS}" "bad-output-proc-sub-git-hook.sh" 'printf "%s\n" <(git status --short >/dev/null)'
assert_fail_contains "git in output process substitution fails static validator" "PERF-03" "${TMP_DIR}/bad-output-proc-sub-git.out" env VIBEGUARD_HOOKS_DIR="${BAD_OUTPUT_PROC_SUB_GIT_HOOKS}" bash "${VALIDATOR}"
assert_file_contains "${TMP_DIR}/bad-output-proc-sub-git.out" "bad-output-proc-sub-git-hook.sh" "output process substitution git names the hook"

BAD_OUTPUT_CHAIN_GIT_HOOKS="${TMP_DIR}/bad-output-chain-git-hooks"
write_hook "${BAD_OUTPUT_CHAIN_GIT_HOOKS}" "bad-output-chain-git-hook.sh" 'printf "%s\n" ok; git status --short >/dev/null'
assert_fail_contains "git chained after output command fails static validator" "PERF-03" "${TMP_DIR}/bad-output-chain-git.out" env VIBEGUARD_HOOKS_DIR="${BAD_OUTPUT_CHAIN_GIT_HOOKS}" bash "${VALIDATOR}"
assert_file_contains "${TMP_DIR}/bad-output-chain-git.out" "bad-output-chain-git-hook.sh" "output chain git names the hook"

BAD_OUTPUT_PIPE_GIT_HOOKS="${TMP_DIR}/bad-output-pipe-git-hooks"
write_hook "${BAD_OUTPUT_PIPE_GIT_HOOKS}" "bad-output-pipe-git-hook.sh" 'echo ok | git status --short >/dev/null'
assert_fail_contains "git piped after output command fails static validator" "PERF-03" "${TMP_DIR}/bad-output-pipe-git.out" env VIBEGUARD_HOOKS_DIR="${BAD_OUTPUT_PIPE_GIT_HOOKS}" bash "${VALIDATOR}"
assert_file_contains "${TMP_DIR}/bad-output-pipe-git.out" "bad-output-pipe-git-hook.sh" "output pipe git names the hook"

BAD_TIMEOUT_CHAIN_GIT_HOOKS="${TMP_DIR}/bad-timeout-chain-git-hooks"
write_hook "${BAD_TIMEOUT_CHAIN_GIT_HOOKS}" "bad-timeout-chain-git-hook.sh" 'timeout 2 git status --short >/dev/null; git status --short >/dev/null'
assert_fail_contains "unsafe git after bounded git fails static validator" "PERF-03" "${TMP_DIR}/bad-timeout-chain-git.out" env VIBEGUARD_HOOKS_DIR="${BAD_TIMEOUT_CHAIN_GIT_HOOKS}" bash "${VALIDATOR}"
assert_file_contains "${TMP_DIR}/bad-timeout-chain-git.out" "bad-timeout-chain-git-hook.sh" "timeout chain git names the hook"

BAD_TIMEOUT_SUB_GIT_HOOKS="${TMP_DIR}/bad-timeout-sub-git-hooks"
write_hook "${BAD_TIMEOUT_SUB_GIT_HOOKS}" "bad-timeout-sub-git-hook.sh" 'timeout 2 git status --short "$(git status --short)" >/dev/null'
assert_fail_contains "git substitution inside bounded git fails static validator" "PERF-03" "${TMP_DIR}/bad-timeout-sub-git.out" env VIBEGUARD_HOOKS_DIR="${BAD_TIMEOUT_SUB_GIT_HOOKS}" bash "${VALIDATOR}"
assert_file_contains "${TMP_DIR}/bad-timeout-sub-git.out" "bad-timeout-sub-git-hook.sh" "timeout substitution git names the hook"

BAD_TIMEOUT_PREFIX_SUB_GIT_HOOKS="${TMP_DIR}/bad-timeout-prefix-sub-git-hooks"
write_hook "${BAD_TIMEOUT_PREFIX_SUB_GIT_HOOKS}" "bad-timeout-prefix-sub-git-hook.sh" 'timeout "$(git config hooks.timeout)" git status --short >/dev/null'
assert_fail_contains "git substitution in timeout argument fails static validator" "PERF-03" "${TMP_DIR}/bad-timeout-prefix-sub-git.out" env VIBEGUARD_HOOKS_DIR="${BAD_TIMEOUT_PREFIX_SUB_GIT_HOOKS}" bash "${VALIDATOR}"
assert_file_contains "${TMP_DIR}/bad-timeout-prefix-sub-git.out" "bad-timeout-prefix-sub-git-hook.sh" "timeout argument substitution git names the hook"

BAD_SUPPRESSED_GIT_HOOKS="${TMP_DIR}/bad-suppressed-git-hooks"
write_hook "${BAD_SUPPRESSED_GIT_HOOKS}" "bad-suppressed-git-hook.sh" '# This comment mentions git status and must not count.
git status --short >/dev/null 2>&1 || true'
assert_fail_contains "error-suppressed git still requires timeout or PERF-OK" "PERF-03" "${TMP_DIR}/bad-suppressed-git.out" env VIBEGUARD_HOOKS_DIR="${BAD_SUPPRESSED_GIT_HOOKS}" bash "${VALIDATOR}"
assert_file_contains "${TMP_DIR}/bad-suppressed-git.out" "bad-suppressed-git-hook.sh" "suppressed git output names the hook"

BAD_LIB_GIT_HOOKS="${TMP_DIR}/bad-lib-git-hooks"
write_hook "${BAD_LIB_GIT_HOOKS}/_lib" "bad-lib.sh" 'git status --short >/dev/null 2>&1 || true'
assert_fail_contains "unsafe helper git call fails static validator" "PERF-03" "${TMP_DIR}/bad-lib-git.out" env VIBEGUARD_HOOKS_DIR="${BAD_LIB_GIT_HOOKS}" bash "${VALIDATOR}"
assert_file_contains "${TMP_DIR}/bad-lib-git.out" "bad-lib.sh" "helper git output names the file"

BAD_EXEC_GIT_HOOKS="${TMP_DIR}/bad-exec-git-hooks"
write_hook "${BAD_EXEC_GIT_HOOKS}/git" "pre-push" 'git status --short >/dev/null 2>&1 || true'
assert_fail_contains "unsafe executable hook git call fails static validator" "PERF-03" "${TMP_DIR}/bad-exec-git.out" env VIBEGUARD_HOOKS_DIR="${BAD_EXEC_GIT_HOOKS}" bash "${VALIDATOR}"
assert_file_contains "${TMP_DIR}/bad-exec-git.out" "pre-push" "executable hook git output names the file"

BAD_LOOP_HOOKS="${TMP_DIR}/bad-loop-hooks"
write_hook "${BAD_LOOP_HOOKS}" "bad-loop-hook.sh" 'while read -r path; do python3 -c "print(1)" "$path"; done < /dev/null'
assert_fail_contains "subprocess in loop fails static validator" "PERF-04" "${TMP_DIR}/bad-loop.out" env VIBEGUARD_HOOKS_DIR="${BAD_LOOP_HOOKS}" bash "${VALIDATOR}"
assert_file_contains "${TMP_DIR}/bad-loop.out" "bad-loop-hook.sh" "loop subprocess output names the hook"

BAD_EXEC_LOOP_HOOKS="${TMP_DIR}/bad-exec-loop-hooks"
write_hook "${BAD_EXEC_LOOP_HOOKS}/git" "pre-commit" 'while read -r path; do python3 -c "print(1)" "$path"; done < /dev/null'
assert_fail_contains "subprocess loop in executable hook fails static validator" "PERF-04" "${TMP_DIR}/bad-exec-loop.out" env VIBEGUARD_HOOKS_DIR="${BAD_EXEC_LOOP_HOOKS}" bash "${VALIDATOR}"
assert_file_contains "${TMP_DIR}/bad-exec-loop.out" "pre-commit" "executable loop output names the hook"

header "dynamic latency gate"
assert_fail_contains "synthetic slow hook fails latency budget" "synthetic-slow-hook" "${TMP_DIR}/slow.out" env VIBEGUARD_BENCH_SPAWN_MAX_MS=100000 bash "${BENCH}" --runs=1 --include-slow-fixture --fail-on-regression --no-bench-action-output
assert_file_contains "${TMP_DIR}/slow.out" "Surface: hook_e2e_ms" "latency gate declares hook e2e surface"
assert_file_contains "${TMP_DIR}/slow.out" "surface=hook_e2e_ms" "latency rows include hook e2e surface marker"
assert_file_contains "${TMP_DIR}/slow.out" "exceeded latency budget" "slow hook output explains budget failure"
assert_file_contains "${TMP_DIR}/slow.out" "hotspot=synthetic sleep fixture" "slow hook output includes hotspot attribution"
assert_file_contains "${TMP_DIR}/slow.out" "codex-wrapper pre-bash-guard" "latency gate includes Codex PreToolUse wrapper fixture"
assert_file_contains "${TMP_DIR}/slow.out" "codex-wrapper post-edit-guard (100)" "latency gate includes Codex PostToolUse wrapper fixture"
assert_file_contains "${TMP_DIR}/slow.out" "post-build-check (fake cargo)" "latency gate includes post-build fake command fixture"
assert_success_contains "JSON latency output is written to override path" "Results: ${BENCH_JSON_TEMP}" "${TMP_DIR}/json.out" env VIBEGUARD_BENCH_SPAWN_MAX_MS=100000 bash "${BENCH}" --runs=1 --json-output="${BENCH_JSON_TEMP}" --bench-action-output="${BENCH_ACTION_TEMP}" --sla=100000
assert_file_contains "${BENCH_JSON_TEMP}" '"surface":"hook_e2e_ms"' "JSON latency output declares hook e2e surface"
assert_file_contains "${BENCH_ACTION_TEMP}" " P50" "benchmark action output includes P50 samples"
assert_file_contains "${BENCH_ACTION_TEMP}" " P95" "benchmark action output includes P95 samples"
assert_file_contains "${BENCH_ACTION_TEMP}" " P99" "benchmark action output includes P99 samples"
assert_file_contains "${BENCH_ACTION_TEMP}" "e2e codex pre-bash P95" "benchmark action output includes compact Codex wrapper samples"
assert_file_contains "${BENCH_ACTION_TEMP}" "e2e post-build fake P95" "benchmark action output includes compact post-build samples"
assert_cmd "benchmark action output parses as JSON" python3 -c 'import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert isinstance(data, list) and data
for row in data:
    assert set(["name", "unit", "value"]) <= set(row)
    assert row["unit"] == "ms"
    assert isinstance(row["value"], (int, float))
' "${BENCH_ACTION_TEMP}"
assert_cmd "contract test does not require repo-root bench-output.json" test ! -e "${ROOT_BENCH_ACTION_FILE}"
assert_file_contains "${REPO_DIR}/docs/reference/hook-latency-contract.md" "Codex wrapper hooks" "latency contract documents wrapper coverage"
assert_file_contains "${REPO_DIR}/docs/reference/hook-latency-contract.md" "core_us" "latency contract documents core microbench surface"
assert_file_contains "${REPO_DIR}/docs/reference/hook-latency-contract.md" "hook_e2e_ms" "latency contract documents hook e2e surface"
assert_file_contains "${REPO_DIR}/docs/internal/benchmarks/benchmark-design.md" "core_us" "benchmark design documents core microbench surface"
assert_file_contains "${REPO_DIR}/docs/internal/benchmarks/benchmark-design.md" "hook_e2e_ms" "benchmark design documents hook e2e surface"
assert_file_contains "${REPO_DIR}/vibeguard-runtime/benches/core_us.rs" 'benchmark_group("core_us")' "core_us benchmark group stays registered"
assert_file_contains "${REPO_DIR}/vibeguard-runtime/benches/core_us.rs" 'bash_destructive_restore' "core_us benchmark keeps bash classifier sample"
assert_file_contains "${REPO_DIR}/vibeguard-runtime/benches/core_us.rs" 'write_clean_rust_fast_path' "core_us benchmark keeps write classifier sample"
assert_success_contains "distorted spawn baseline suppresses latency failure" "ENVIRONMENT DISTORTED" "${TMP_DIR}/distorted.out" env VIBEGUARD_BENCH_SPAWN_BASELINE_MS=999 VIBEGUARD_BENCH_SPAWN_MAX_MS=10 bash "${BENCH}" --runs=1 --include-slow-fixture --fail-on-regression --no-bench-action-output

header "benchmark score gate"
BENCHMARK_CSV="${TMP_DIR}/precision-fixture.csv"
cat > "${BENCHMARK_CSV}" <<'CSV'
hook,case,type,rule,expect,detected,passed,latency
pre-bash-guard,tp-case,tp,rule,block,1,1,5
pre-bash-guard,fp-case,fp,rule,allow,0,1,5
CSV
assert_success_contains "fast benchmark reuses precision CSV fixture" "Cases: 2" "${TMP_DIR}/benchmark.out" env VIBEGUARD_BENCHMARK_RESULTS_DIR="${TMP_DIR}/benchmark-results" VG_PRECISION_CSV_FILE="${BENCHMARK_CSV}" bash "${BENCHMARK}" --mode=fast
assert_fail_contains "fast benchmark fails on missing precision CSV" "VG_PRECISION_CSV_FILE does not exist" "${TMP_DIR}/benchmark-missing.out" env VIBEGUARD_BENCHMARK_RESULTS_DIR="${TMP_DIR}/benchmark-missing-results" VG_PRECISION_CSV_FILE="${TMP_DIR}/missing-precision.csv" bash "${BENCHMARK}" --mode=fast
assert_success_contains "precision threshold validator accepts CSV fixture" "F1:" "${TMP_DIR}/threshold.out" env VG_PRECISION_CSV_FILE="${BENCHMARK_CSV}" bash "${THRESHOLD_VALIDATOR}"

EMPTY_BENCHMARK_CSV="${TMP_DIR}/precision-empty.csv"
cat > "${EMPTY_BENCHMARK_CSV}" <<'CSV'
hook,case,type,rule,expect,detected,passed,latency
CSV
assert_fail_contains "fast benchmark fails on empty precision CSV" "zero precision rows parsed" "${TMP_DIR}/benchmark-empty.out" env VIBEGUARD_BENCHMARK_RESULTS_DIR="${TMP_DIR}/benchmark-empty-results" VG_PRECISION_CSV_FILE="${EMPTY_BENCHMARK_CSV}" bash "${BENCHMARK}" --mode=fast
assert_fail_contains "precision threshold validator fails on empty CSV" "zero precision rows parsed" "${TMP_DIR}/threshold-empty.out" env VG_PRECISION_CSV_FILE="${EMPTY_BENCHMARK_CSV}" bash "${THRESHOLD_VALIDATOR}"

MALFORMED_BENCHMARK_CSV="${TMP_DIR}/precision-malformed.csv"
cat > "${MALFORMED_BENCHMARK_CSV}" <<'CSV'
hook,case,type,rule,expect,detected,passed,latency
pre-bash-guard,tp-case,tp
CSV
assert_fail_contains "fast benchmark fails on malformed precision CSV" "malformed precision CSV line" "${TMP_DIR}/benchmark-malformed.out" env VIBEGUARD_BENCHMARK_RESULTS_DIR="${TMP_DIR}/benchmark-malformed-results" VG_PRECISION_CSV_FILE="${MALFORMED_BENCHMARK_CSV}" bash "${BENCHMARK}" --mode=fast

BAD_DETECTED_BENCHMARK_CSV="${TMP_DIR}/precision-bad-detected.csv"
cat > "${BAD_DETECTED_BENCHMARK_CSV}" <<'CSV'
hook,case,type,rule,expect,detected,passed,latency
pre-bash-guard,tp-case,tp,rule,block,maybe,1,5
CSV
assert_fail_contains "fast benchmark fails on invalid detected value" "invalid detected value" "${TMP_DIR}/benchmark-bad-detected.out" env VIBEGUARD_BENCHMARK_RESULTS_DIR="${TMP_DIR}/benchmark-bad-detected-results" VG_PRECISION_CSV_FILE="${BAD_DETECTED_BENCHMARK_CSV}" bash "${BENCHMARK}" --mode=fast
assert_fail_contains "precision threshold validator fails on invalid detected value" "invalid detected value" "${TMP_DIR}/threshold-bad-detected.out" env VG_PRECISION_CSV_FILE="${BAD_DETECTED_BENCHMARK_CSV}" bash "${THRESHOLD_VALIDATOR}"

echo ""
echo "======================================"
echo "Hook performance contract tests: ${PASS}/${TOTAL} passed"
echo "======================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi

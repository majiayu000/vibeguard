#!/usr/bin/env bash
# VibeGuard health report regression testing
#
# Usage: bash tests/test_health_report.sh
#
# Uses the real vibeguard-runtime binary (built here) as the observe source and
# temporary event/triage/scorecard/adoption fixtures for everything else, so the
# aggregator is exercised end to end without touching installed user config.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${REPO_DIR}/scripts/health-report.py"

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header(){ printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

assert_contains() {
  local output="$1" expected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qF "$expected" <<< "$output"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected to contain: $expected)"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

header "build runtime for observe source"
if ! command -v cargo >/dev/null 2>&1; then
  echo "tests/test_health_report.sh requires cargo to build vibeguard-runtime" >&2
  exit 1
fi
cargo build --manifest-path "${REPO_DIR}/vibeguard-runtime/Cargo.toml" --quiet
RUNTIME="${REPO_DIR}/vibeguard-runtime/target/debug/vibeguard-runtime"
export VIBEGUARD_RUNTIME="${RUNTIME}"

# --- Fixtures --------------------------------------------------------------
EVENTS="${TMP_DIR}/events.jsonl"
cat > "${EVENTS}" <<'JSONL'
{"ts":"2026-07-01T00:00:01Z","session":"s1","hook":"pre-bash-guard","decision":"pass","duration_ms":10,"client":"codex"}
{"ts":"2026-07-01T00:00:02Z","session":"s1","hook":"post-edit-guard","decision":"warn","reason":"U-16","rule":"U-16","duration_ms":30,"client":"codex"}
{"ts":"2026-07-01T00:00:03Z","session":"s2","hook":"pre-bash-guard","decision":"block","reason":"SEC-01","rule":"SEC-01","duration_ms":5,"client":"claude"}
JSONL

# Scorecard with a rule (RS-03) that never appears in the event log, so the
# 30-day window must flag it as a zero-trigger downgrade candidate.
SCORECARD="${TMP_DIR}/scorecard.json"
cat > "${SCORECARD}" <<'JSON'
{"rules":{"RS-03":{"stage":"warn","precision":null,"samples":0,"tp":0,"fp":0,"acceptable":0,"last_fp_ts":null,"stage_entered_ts":"2026-01-01T00:00:00Z","notes":"unwrap"}}}
JSON

TRIAGE_CLEAN="${TMP_DIR}/triage-clean.jsonl"
cat > "${TRIAGE_CLEAN}" <<'JSONL'
{"ts":"2026-06-01T00:00:00Z","rule":"RS-03","verdict":"tp"}
{"ts":"2026-06-02T00:00:00Z","rule":"RS-03","verdict":"fp"}
JSONL

# A triage candidate with no rule id must land in the backlog, not crash.
TRIAGE_NORULE="${TMP_DIR}/triage-norule.jsonl"
cat > "${TRIAGE_NORULE}" <<'JSONL'
{"ts":"2026-06-03T00:00:00Z","verdict":"unclassified","context":"W-13 event with no rule id"}
JSONL

# A malformed JSONL line must fail the whole report loudly.
TRIAGE_BAD="${TMP_DIR}/triage-bad.jsonl"
cat > "${TRIAGE_BAD}" <<'JSONL'
this is not json
JSONL

EMPTY_ADOPT="${TMP_DIR}/adoptions.jsonl"
: > "${EMPTY_ADOPT}"

run_report() {
  python3 "${SCRIPT}" \
    --scorecard-file "${SCORECARD}" \
    --adoptions-file "${EMPTY_ADOPT}" \
    "$@"
}

# --- Tests -----------------------------------------------------------------
header "markdown output"
md_out="$(run_report --days 30 --log-file "${EVENTS}" --triage-file "${TRIAGE_CLEAN}" --format markdown)"
assert_contains "$md_out" "# VibeGuard Health Report" "markdown renders report header"
assert_contains "$md_out" "Scope: **project**" "markdown states scope explicitly"

header "decision distribution present"
assert_contains "$md_out" "block=1" "markdown includes block decision count"
assert_contains "$md_out" "warn=1" "markdown includes warn decision count"
assert_contains "$md_out" "pass=1" "markdown includes pass decision count"

header "json output"
json_out="$(run_report --days 30 --log-file "${EVENTS}" --triage-file "${TRIAGE_CLEAN}" --format json)"
for key in schema_version window_days scope generated_ts data_sources overview \
           rule_triggers precision_risks unclassified_backlog idle_assets \
           downgrade_candidates follow_up_actions; do
  assert_contains "$json_out" "\"${key}\"" "json schema has ${key}"
done
assert_contains "$json_out" "\"decision_distribution\"" "json overview carries decision distribution"

header "no-data visible state (missing log)"
nodata_out="$(run_report --days 7 --log-file "${TMP_DIR}/does-not-exist.jsonl" --triage-file "${TRIAGE_CLEAN}" --format markdown)"
assert_contains "$nodata_out" "NO DATA" "missing event log renders explicit no-data state"

header "malformed triage fails loudly"
TOTAL=$((TOTAL + 1))
if err_out="$(run_report --days 30 --log-file "${EVENTS}" --triage-file "${TRIAGE_BAD}" --format json 2>&1)"; then
  red "malformed triage JSONL must exit non-zero"
  FAIL=$((FAIL + 1))
else
  if grep -qiF "malformed" <<< "$err_out"; then
    green "malformed triage JSONL exits non-zero with error message"
    PASS=$((PASS + 1))
  else
    red "malformed triage JSONL exited non-zero but without a clear error (got: $err_out)"
    FAIL=$((FAIL + 1))
  fi
fi

header "missing rule id -> unclassified backlog"
backlog_out="$(run_report --days 30 --log-file "${EVENTS}" --triage-file "${TRIAGE_NORULE}" --format json)"
assert_contains "$backlog_out" "missing rule id" "rule-id-less candidate goes to unclassified_backlog"

header "30-day zero-trigger -> downgrade candidate"
downgrade_out="$(run_report --days 30 --log-file "${EVENTS}" --triage-file "${TRIAGE_CLEAN}" --format json)"
assert_contains "$downgrade_out" "\"zero_trigger_rules\"" "idle_assets exposes zero_trigger_rules"
assert_contains "$downgrade_out" "RS-03" "untriggered scorecard rule listed as downgrade candidate"

header "scope stays explicit (global)"
global_out="$(run_report --scope global --days 30 --log-file "${EVENTS}" --triage-file "${TRIAGE_CLEAN}" --format markdown)"
assert_contains "$global_out" "Scope: **global**" "global scope reported explicitly"

# --- Summary ---------------------------------------------------------------
printf '\n\033[1m=== Summary ===\033[0m\n'
printf 'Total: %d  Passed: %d  Failed: %d\n' "$TOTAL" "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi

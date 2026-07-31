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
# Fixture timestamps are generated relative to now. The report filters events by
# a rolling `--days` window, so hardcoded dates silently age out of it and turn
# these assertions red on a date unrelated to any code change.
fixture_ts() {
  local hours_ago="$1"
  python3 -c "
import datetime, sys
moment = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=int(sys.argv[1]))
print(moment.strftime('%Y-%m-%dT%H:%M:%SZ'))
" "${hours_ago}"
}

EVENT_TS_PASS="$(fixture_ts 24)"
EVENT_TS_WARN="$(fixture_ts 23)"
EVENT_TS_BLOCK="$(fixture_ts 22)"

EVENTS="${TMP_DIR}/events.jsonl"
cat > "${EVENTS}" <<JSONL
{"ts":"${EVENT_TS_PASS}","session":"s1","hook":"pre-bash-guard","decision":"pass","duration_ms":10,"client":"codex"}
{"ts":"${EVENT_TS_WARN}","session":"s1","hook":"post-edit-guard","decision":"warn","reason":"U-16","rule":"U-16","duration_ms":30,"client":"codex"}
{"ts":"${EVENT_TS_BLOCK}","session":"s2","hook":"pre-bash-guard","decision":"block","reason":"SEC-01","rule":"SEC-01","duration_ms":5,"client":"claude"}
JSONL

# Scorecard with a rule (RS-03) that never appears in the event log, so the
# 30-day window must flag it as a zero-trigger downgrade candidate.
SCORECARD="${TMP_DIR}/scorecard.json"
cat > "${SCORECARD}" <<JSON
{"rules":{"RS-03":{"stage":"warn","precision":null,"samples":0,"tp":0,"fp":0,"acceptable":0,"last_fp_ts":null,"stage_entered_ts":"$(fixture_ts 4800)","notes":"unwrap"}}}
JSON

TRIAGE_CLEAN="${TMP_DIR}/triage-clean.jsonl"
cat > "${TRIAGE_CLEAN}" <<JSONL
{"ts":"$(fixture_ts 48)","rule":"RS-03","verdict":"tp"}
{"ts":"$(fixture_ts 47)","rule":"RS-03","verdict":"fp"}
JSONL

# A triage candidate with no rule id must land in the backlog, not crash.
TRIAGE_NORULE="${TMP_DIR}/triage-norule.jsonl"
cat > "${TRIAGE_NORULE}" <<JSONL
{"ts":"$(fixture_ts 46)","verdict":"unclassified","context":"W-13 event with no rule id"}
JSONL

# A malformed JSONL line must fail the whole report loudly.
TRIAGE_BAD="${TMP_DIR}/triage-bad.jsonl"
cat > "${TRIAGE_BAD}" <<'JSONL'
this is not json
JSONL

EMPTY_ADOPT="${TMP_DIR}/adoptions.jsonl"
: > "${EMPTY_ADOPT}"

FAKE_RUNTIME="${TMP_DIR}/fake-runtime"
cat > "${FAKE_RUNTIME}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

command_name="${2:-}"
mode="${FAKE_BLOCK_MODE:-legacy}"
if [[ "$command_name" == "summary" ]]; then
  case "$mode" in
    legacy)
      printf '%s\n' '{"event_count":2,"decision_counts":{"block":1,"pass":1},"time_range":{"first_ts":"2026-07-01T00:00:00Z","last_ts":"2026-07-01T00:00:01Z"},"attention":{"rate":0.5},"top_rule_ids":[]}'
      ;;
    bad_structure)
      printf '%s\n' '{"event_count":2,"decision_counts":{"block":1,"pass":1},"block_counts":{"total_blocks":"1","protocol_errors":0,"non_protocol_blocks":1},"time_range":{},"attention":{},"top_rule_ids":[]}'
      ;;
    bad_arithmetic)
      printf '%s\n' '{"event_count":2,"decision_counts":{"block":2},"block_counts":{"total_blocks":2,"protocol_errors":2,"non_protocol_blocks":1},"time_range":{},"attention":{},"top_rule_ids":[]}'
      ;;
    *)
      exit 9
      ;;
  esac
else
  printf '%s\n' '{"event_count":0,"decision_counts":{},"attention_states":[],"diagnostics":[]}'
fi
SH
chmod +x "${FAKE_RUNTIME}"

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
assert_contains "$md_out" "Block split: **available**" "markdown marks block split available"
assert_contains "$md_out" "Total blocks: 1" "markdown includes total block count"
assert_contains "$md_out" "Protocol errors: 0" "markdown includes protocol error count"
assert_contains "$md_out" "Non-protocol blocks: 1" "markdown includes non-protocol block count"

header "json output"
json_out="$(run_report --days 30 --log-file "${EVENTS}" --triage-file "${TRIAGE_CLEAN}" --format json)"
for key in schema_version window_days scope generated_ts data_sources overview \
           rule_triggers precision_risks unclassified_backlog idle_assets \
           downgrade_candidates follow_up_actions; do
  assert_contains "$json_out" "\"${key}\"" "json schema has ${key}"
done
assert_contains "$json_out" "\"decision_distribution\"" "json overview carries decision distribution"
assert_contains "$json_out" '"block_counts_status": "available"' "json marks block split available"
assert_contains "$json_out" '"total_blocks": 1' "json overview carries total block count"

header "legacy runtime block split unavailable"
legacy_md="$(VIBEGUARD_RUNTIME="${FAKE_RUNTIME}" FAKE_BLOCK_MODE=legacy run_report --days 30 --log-file "${EVENTS}" --triage-file "${TRIAGE_CLEAN}" --format markdown)"
assert_contains "$legacy_md" "Block split: **unavailable**" "legacy runtime markdown marks split unavailable"
assert_contains "$legacy_md" "unavailable from installed runtime" "legacy runtime markdown explains unavailable split"
legacy_json="$(VIBEGUARD_RUNTIME="${FAKE_RUNTIME}" FAKE_BLOCK_MODE=legacy run_report --days 30 --log-file "${EVENTS}" --triage-file "${TRIAGE_CLEAN}" --format json)"
assert_contains "$legacy_json" '"block_counts_status": "unavailable"' "legacy runtime JSON marks split unavailable"
assert_contains "$legacy_json" '"block_counts": null' "legacy runtime JSON does not guess split"

header "no-data visible state (missing log)"
nodata_out="$(run_report --days 7 --log-file "${TMP_DIR}/does-not-exist.jsonl" --triage-file "${TRIAGE_CLEAN}" --format markdown)"
assert_contains "$nodata_out" "NO DATA" "missing event log renders explicit no-data state"
nodata_json="$(run_report --days 7 --log-file "${TMP_DIR}/does-not-exist.jsonl" --triage-file "${TRIAGE_CLEAN}" --format json)"
assert_contains "$nodata_json" '"block_counts_status": "no_data"' "missing event log JSON prioritizes no-data state"
assert_contains "$nodata_json" '"block_counts": null' "missing event log JSON does not report zero-risk split"
assert_contains "$nodata_json" '"RS-03"' "no-data report retains independent precision evidence"
assert_contains "$nodata_json" '"at_risk": true' "no-data report retains independent precision risk conclusion"

EMPTY_EVENTS="${TMP_DIR}/empty-events.jsonl"
: > "${EMPTY_EVENTS}"
empty_json="$(run_report --days 7 --log-file "${EMPTY_EVENTS}" --triage-file "${TRIAGE_CLEAN}" --format json)"
assert_contains "$empty_json" '"block_counts_status": "no_data"' "empty event window JSON prioritizes no-data state"

header "malformed block counts fail loudly"
for bad_mode in bad_structure bad_arithmetic; do
  TOTAL=$((TOTAL + 1))
  if bad_out="$(VIBEGUARD_RUNTIME="${FAKE_RUNTIME}" FAKE_BLOCK_MODE="${bad_mode}" run_report --days 30 --log-file "${EVENTS}" --triage-file "${TRIAGE_CLEAN}" --format json 2>&1)"; then
    red "${bad_mode} block counts must exit non-zero"
    FAIL=$((FAIL + 1))
  elif grep -qiF "block_counts" <<< "$bad_out"; then
    green "${bad_mode} block counts fail loudly"
    PASS=$((PASS + 1))
  else
    red "${bad_mode} block counts failed without a clear block_counts error (got: $bad_out)"
    FAIL=$((FAIL + 1))
  fi
done

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

header "read-only repeatability"
before_hash="$(shasum -a 256 "${EVENTS}" | awk '{print $1}')"
repeat_one="$(run_report --days 30 --log-file "${EVENTS}" --triage-file "${TRIAGE_CLEAN}" --format json)"
repeat_two="$(run_report --days 30 --log-file "${EVENTS}" --triage-file "${TRIAGE_CLEAN}" --format json)"
after_hash="$(shasum -a 256 "${EVENTS}" | awk '{print $1}')"
TOTAL=$((TOTAL + 1))
if python3 -c 'import json,sys; a=json.loads(sys.argv[1]); b=json.loads(sys.argv[2]); a.pop("generated_ts",None); b.pop("generated_ts",None); raise SystemExit(a != b)' "$repeat_one" "$repeat_two"; then
  green "repeated health reports are semantically deterministic"
  PASS=$((PASS + 1))
else
  red "repeated health reports drift beyond generated timestamp"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
if [[ "$before_hash" == "$after_hash" ]]; then
  green "health report does not append or rewrite event logs"
  PASS=$((PASS + 1))
else
  red "health report changed the event log"
  FAIL=$((FAIL + 1))
fi

# --- Summary ---------------------------------------------------------------
printf '\n\033[1m=== Summary ===\033[0m\n'
printf 'Total: %d  Passed: %d  Failed: %d\n' "$TOTAL" "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi

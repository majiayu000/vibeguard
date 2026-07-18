#!/usr/bin/env bash
# VibeGuard Learn adoption compiler and verification tests.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

PASS=0
FAIL=0
TOTAL=0
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header(){ printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

assert_cmd() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    green "$desc"; PASS=$((PASS + 1))
  else
    red "$desc"; FAIL=$((FAIL + 1))
  fi
}

assert_fails() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    red "$desc (expected failure)"; FAIL=$((FAIL + 1))
  else
    green "$desc"; PASS=$((PASS + 1))
  fi
}

state_file="${TMP_DIR}/learn-state.jsonl"
adoptions_file="${TMP_DIR}/learn-adoptions.jsonl"

header "learn adoption compiler"
assert_cmd "learn adoption helper compiles" python3 -m py_compile scripts/learn/adoption.py

runtime_signal="${TMP_DIR}/runtime-signal.json"
cat > "$runtime_signal" <<'JSON'
{
  "schema_version": 1,
  "signal_id": "lrn_runtime_001",
  "observation_id": "obs_runtime_001",
  "classification": "runtime_health",
  "type": "metrics_truncation",
  "evidence_samples": [{"summary": "learn metrics input was truncated"}],
  "recommended_actions": [
    {"type": "fix_runtime", "rationale": "runtime pipeline issue", "target": "hooks/learn-evaluator.sh"},
    {"type": "add_rule", "rationale": "wrong action"}
  ]
}
JSON

runtime_out="${TMP_DIR}/runtime-adopt.json"
_VIBEGUARD_TEST_NOW="2026-06-25T00:00:00Z" python3 scripts/learn/adoption.py \
  --state-file "$state_file" \
  --adoptions-file "$adoptions_file" \
  adopt \
  --signal "$runtime_signal" \
  --action fix_runtime \
  --artifact hooks/learn-evaluator.sh \
  --verification-command "bash tests/test_gc_scheduled.sh" \
  --regression-command "bash tests/test_gc_scheduled.sh" \
  --baseline "18 truncated sessions" \
  --expected-observation "truncation recurrence falls in next window" \
  --rollback "revert runtime pipeline change" \
  --reason "adopt runtime fix" > "$runtime_out"

assert_cmd "runtime-health adoption records full verification bundle" python3 - "$runtime_out" "$adoptions_file" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
records = [json.loads(line) for line in Path(sys.argv[2]).read_text(encoding="utf-8").splitlines()]
record = records[-1]
assert payload["mode"] == "adopt", payload
assert payload["action"]["type"] == "fix_runtime", payload
assert payload["verification"]["status"] == "pending", payload
assert record["verification_commands"] == ["bash tests/test_gc_scheduled.sh"], record
assert record["regression_checks"] == ["bash tests/test_gc_scheduled.sh"], record
assert record["baseline"] == "18 truncated sessions", record
assert record["expected_later_observation"], record
assert record["rollback_path"], record
assert record["state_transition"]["to"] == "adopted", record
PY

assert_fails "runtime-health cannot adopt guard/rule action" python3 scripts/learn/adoption.py \
  --state-file "$state_file" \
  --adoptions-file "$adoptions_file" \
  adopt \
  --signal "$runtime_signal" \
  --action add_rule \
  --verification-command "bash tests/test_gc_scheduled.sh" \
  --regression-command "bash tests/test_gc_scheduled.sh" \
  --baseline "baseline" \
  --expected-observation "later" \
  --rollback "rollback" \
  --reason "bad action"

friction_signal="${TMP_DIR}/friction-signal.json"
cat > "$friction_signal" <<'JSON'
{
  "schema_version": 1,
  "signal_id": "lrn_friction_001",
  "observation_id": "obs_friction_001",
  "classification": "defense_friction",
  "type": "repeated_warn",
  "evidence_samples": [{"summary": "docs examples repeatedly trigger RS-03"}],
  "recommended_actions": [
    {"type": "add_scoped_suppression", "rationale": "known false positive", "target": ".vibeguard.json"}
  ]
}
JSON

friction_out="${TMP_DIR}/friction-adopt.json"
_VIBEGUARD_TEST_NOW="2026-06-25T00:00:00Z" python3 scripts/learn/adoption.py \
  --state-file "$state_file" \
  --adoptions-file "$adoptions_file" \
  adopt \
  --signal "$friction_signal" \
  --action add_scoped_suppression \
  --artifact .vibeguard.json \
  --verification-command "cargo test --manifest-path vibeguard-runtime/Cargo.toml scoped_suppression" \
  --regression-command "bash tests/hooks/test_post_edit_suppression.sh" \
  --baseline "docs examples trigger RS-03" \
  --expected-observation "same docs examples no longer warn while nonmatching paths still warn" \
  --rollback "remove scoped_suppressions entry" \
  --reason "adopt scoped suppression" > "$friction_out"

assert_cmd "defense-friction adoption uses scoped_suppressions governance" python3 - "$friction_out" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
governance = payload["adoption"]["governance"]
assert governance["config_key"] == "scoped_suppressions", governance
assert governance["artifact"] == ".vibeguard.json", governance
PY

noise_signal="${TMP_DIR}/noise-signal.json"
cat > "$noise_signal" <<'JSON'
{
  "schema_version": 1,
  "signal_id": "lrn_noise_001",
  "observation_id": "obs_noise_001",
  "classification": "noise",
  "type": "edit_path",
  "evidence_samples": [{"summary": "external temp path"}],
  "recommended_actions": [
    {"type": "no_action", "rationale": "external path is not project evidence"}
  ]
}
JSON

noise_out="${TMP_DIR}/noise-adopt.json"
_VIBEGUARD_TEST_NOW="2026-06-25T00:00:00Z" python3 scripts/learn/adoption.py \
  --state-file "$state_file" \
  --adoptions-file "$adoptions_file" \
  adopt \
  --signal "$noise_signal" \
  --action no_action \
  --verification-command "python3 scripts/learn/analyze.py --scope current --dry-run --no-code-scan" \
  --regression-command "python3 scripts/learn/analyze.py --scope current --dry-run --no-code-scan" \
  --baseline "external temp path diagnostic" \
  --expected-observation "external path remains diagnostic noise only" \
  --rollback "none" \
  --reason "ignore noise" > "$noise_out"

assert_cmd "noise no-action transition is skipped not adopted" python3 - "$noise_out" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["action"]["type"] == "no_action", payload
assert payload["state_transition"]["to"] == "skipped", payload
PY

fresh_evidence="${TMP_DIR}/fresh-evidence.json"
cat > "$fresh_evidence" <<'JSON'
{
  "signal_id": "lrn_runtime_001",
  "observed_at": "2026-06-26T00:00:00Z",
  "recurrence_delta": -12,
  "regression_signals": []
}
JSON
verify_out="${TMP_DIR}/verify.json"
_VIBEGUARD_TEST_NOW="2026-06-26T00:00:01Z" python3 scripts/learn/adoption.py \
  --state-file "$state_file" \
  --adoptions-file "$adoptions_file" \
  verify \
  --signal-id lrn_runtime_001 \
  --evidence "$fresh_evidence" \
  --reason "fresh window improved" > "$verify_out"

assert_cmd "fresh evidence can verify an adopted signal" python3 - "$verify_out" "$state_file" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
states = [json.loads(line) for line in Path(sys.argv[2]).read_text(encoding="utf-8").splitlines()]
assert payload["verification"]["status"] == "verified", payload
assert payload["verification"]["evidence_observed_at"] == "2026-06-26T00:00:00Z", payload
assert states[-1]["to"] == "verified", states[-1]
PY

stale_evidence="${TMP_DIR}/stale-evidence.json"
cat > "$stale_evidence" <<'JSON'
{
  "signal_id": "lrn_runtime_001",
  "observed_at": "2026-06-24T00:00:00Z",
  "recurrence_delta": -12,
  "regression_signals": []
}
JSON
assert_fails "verification rejects stale pre-adoption evidence" python3 scripts/learn/adoption.py \
  --state-file "$state_file" \
  --adoptions-file "$adoptions_file" \
  verify \
  --signal-id lrn_runtime_001 \
  --evidence "$stale_evidence" \
  --reason "stale"

printf "\n==============================\n"
printf "Total: %d  Pass: %d  Fail: %d\n" "$TOTAL" "$PASS" "$FAIL"
printf "==============================\n"

if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi

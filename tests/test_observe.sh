#!/usr/bin/env bash
# Regression tests for vibeguard-runtime observe summary|health|session.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="${REPO_DIR}/vibeguard-runtime/target/debug/vibeguard-runtime"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

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
    red "$desc (cmd: $*)"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local output="$1" expected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$output" | grep -qF -- "$expected"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected to contain: $expected)"
    FAIL=$((FAIL + 1))
  fi
}

header "build"
assert_cmd "vibeguard-runtime builds" cargo build --manifest-path "${REPO_DIR}/vibeguard-runtime/Cargo.toml" --quiet

EVENT_LOG="${TMP_DIR}/events.jsonl"
SUMMARY_JSON="${TMP_DIR}/summary.json"
HEALTH_JSON="${TMP_DIR}/health.json"
SESSION_JSON="${TMP_DIR}/session.json"

cat > "${EVENT_LOG}" <<'JSONL'
{"ts":"2026-06-01T00:00:01Z","session":"s1","hook":"pre-bash-guard","tool":"Bash","decision":"pass","reason":"","detail":"git status","duration_ms":10,"client":"codex"}
not json
{"ts":"2026-06-01T00:00:02Z","session":"s1","hook":"post-edit-guard","tool":"Edit","decision":"warn","reason":"U-16 file too large","detail":"src/main.rs","duration_ms":30,"client":"codex"}
{"ts":"2026-06-01T00:00:03Z","session":"s2","hook":"pre-write-guard","tool":"Write","decision":"block","reason":"SEC-13 high-context risk","detail":"AGENTS.md","duration_ms":20,"client":"claude"}
{"ts":"2026-06-01T00:00:04Z","session":"s1","hook":"post-build-check","tool":"PostToolUse","decision":"pass","reason":"skip: no file","detail":"","duration_ms":5,"client":"codex"}
{"ts":"2026-06-01T00:00:05Z","session":"s1","hook":"post-write-guard","tool":"Write","decision":"pass","reason":"","detail":"src/lib.rs","duration_ms":2500,"client":"codex"}
{"ts":"2026-06-01T00:00:06Z","session":"s1","hook":"post-build-check","tool":"PostToolUse","status":"timeout","reason":"post-build-check timeout after 30s","detail":"cargo test","duration_ms":30000,"client":"codex"}
{"ts":"2026-06-01T00:00:07Z","session":"s1","hook":"codex-wrapper","event":"PostToolUse","status":"hook_error","reason":"missing-runner","detail":"wrapper unavailable","duration_ms":1,"client":"codex"}
JSONL

header "summary json"
"${RUNTIME}" observe summary --json --days all --log-file "${EVENT_LOG}" --slow-ms 2000 > "${SUMMARY_JSON}"
assert_cmd "summary: output parses" python3 -c "import json; json.load(open('${SUMMARY_JSON}'))"
assert_cmd "summary: schema validates" python3 - <<'PY' "${REPO_DIR}" "${SUMMARY_JSON}"
import importlib.util
import json
import sys
from pathlib import Path

repo = Path(sys.argv[1])
data = json.load(open(sys.argv[2], encoding="utf-8"))
schema = json.loads((repo / "schemas/observe-output.schema.json").read_text(encoding="utf-8"))
spec = importlib.util.spec_from_file_location("workflow_contracts", repo / "scripts/lib/workflow_contracts.py")
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
errors = module.validate_instance(data, schema)
if errors:
    raise SystemExit("\n".join(errors))
PY
assert_cmd "summary: required aggregates are present" python3 - <<'PY' "${SUMMARY_JSON}"
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
if data["event_count"] != 7:
    raise SystemExit(f"malformed JSONL should be skipped, got {data['event_count']}")
if data["decision_counts"].get("pass") != 3:
    raise SystemExit(f"unexpected pass count: {data['decision_counts']}")
if data["client_distribution"].get("codex") != 6:
    raise SystemExit(f"unexpected client distribution: {data['client_distribution']}")
rules = {item["value"] for item in data["top_rule_ids"]}
if {"U-16", "SEC-13"} - rules:
    raise SystemExit(f"missing rule ids: {rules}")
if data["duration_stats"]["slow_count"] != 2:
    raise SystemExit(f"unexpected slow count: {data['duration_stats']}")
PY

header "health json"
"${RUNTIME}" observe health --json --hours all --log-file "${EVENT_LOG}" --slow-ms 2000 > "${HEALTH_JSON}"
assert_cmd "health: attention states and diagnostics are separated" python3 - <<'PY' "${HEALTH_JSON}"
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
attention_statuses = {entry["status"] for entry in data["attention_states"]}
if attention_statuses != {"warn", "block"}:
    raise SystemExit(f"unexpected attention statuses: {attention_statuses}")
diagnostics = {entry["diagnostic"] for entry in data["diagnostics"]}
if {"slow", "timeout", "hook_error"} - diagnostics:
    raise SystemExit(f"missing diagnostics: {diagnostics}")
for entry in data["diagnostics"]:
    if entry["status"] in {"pass", "skipped", "slow", "timeout", "hook_error"} and entry["model_context"]:
        raise SystemExit(f"diagnostic must not inject model context: {entry}")
PY

header "session json"
"${RUNTIME}" observe session s1 --json --hours all --log-file "${EVENT_LOG}" --slow-ms 2000 > "${SESSION_JSON}"
assert_cmd "session: output excludes other sessions" python3 - <<'PY' "${SESSION_JSON}"
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
if data["event_count"] != 6:
    raise SystemExit(f"expected six s1 events, got {data['event_count']}")
sessions = {entry["session"] for entry in data["recent_events"]}
if sessions != {"s1"}:
    raise SystemExit(f"session output leaked other sessions: {sessions}")
rules = {item["value"] for item in data["top_rule_ids"]}
if "SEC-13" in rules:
    raise SystemExit(f"session output leaked s2 reason codes: {rules}")
PY

header "human output"
human_out="$("${RUNTIME}" observe summary --days all --log-file "${EVENT_LOG}" --slow-ms 2000 2>&1)"
assert_contains "${human_out}" "VibeGuard observe summary" "human: summary has concise title"
assert_contains "${human_out}" "Top hooks:" "human: summary includes top hooks"

printf '\n'
if [[ "$FAIL" -eq 0 ]]; then
  printf '\033[32mAll %d/%d tests passed\033[0m\n' "$PASS" "$TOTAL"
  exit 0
else
  printf '\033[31m%d/%d tests failed\033[0m\n' "$FAIL" "$TOTAL"
  exit 1
fi

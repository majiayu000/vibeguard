#!/usr/bin/env bash
# VibeGuard stats regression testing
#
# Usage: bash tests/test_stats.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${REPO_DIR}/scripts/stats.sh"

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

assert_not_contains() {
  local output="$1" forbidden="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qF "$forbidden" <<< "$output"; then
    red "$desc (must not contain: $forbidden)"
    FAIL=$((FAIL + 1))
  else
    green "$desc"
    PASS=$((PASS + 1))
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

RUNTIME="${REPO_DIR}/vibeguard-runtime/target/debug/vibeguard-runtime"

header "build"
assert_cmd "vibeguard-runtime builds for observe wrappers" \
  cargo build --manifest-path "${REPO_DIR}/vibeguard-runtime/Cargo.toml" --quiet

header "Project and explicit log scope"
SCOPE_ROOT="${TMP_DIR}/scope"
SCOPE_PROJECT_DIR="${SCOPE_ROOT}/projects/abcdef12"
mkdir -p "${SCOPE_PROJECT_DIR}"
printf '%s' "${REPO_DIR}" > "${SCOPE_PROJECT_DIR}/.project-root"
python3 - "${SCOPE_PROJECT_DIR}/events.jsonl" "${SCOPE_ROOT}/events.jsonl" "${TMP_DIR}/explicit-events.jsonl" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone

project_path, global_path, explicit_path = sys.argv[1:4]
now = datetime.now(timezone.utc)

def event(session, detail):
    return {
        "ts": (now - timedelta(hours=1)).isoformat().replace("+00:00", "Z"),
        "session": session,
        "hook": "pre-bash-guard",
        "tool": "Bash",
        "decision": "warn",
        "reason": detail,
        "detail": detail,
    }

for path, payload in [
    (project_path, event("project-scope", "project-only")),
    (global_path, event("global-scope", "global-only")),
    (explicit_path, event("explicit-scope", "explicit-only")),
]:
    with open(path, "w", encoding="utf-8") as f:
        f.write(json.dumps(payload) + "\n")
PY

project_scope_out="$(cd "${REPO_DIR}" && VIBEGUARD_LOG_DIR="${SCOPE_ROOT}" bash "${SCRIPT}" 7 2>&1)"
assert_contains "${project_scope_out}" "project-only" "Default scope reads current project log"
assert_not_contains "${project_scope_out}" "global-only" "Default project scope does not read global log"

global_scope_out="$(cd "${REPO_DIR}" && VIBEGUARD_LOG_DIR="${SCOPE_ROOT}" bash "${SCRIPT}" --scope global 7 2>&1)"
assert_contains "${global_scope_out}" "global-only" "--scope global reads global log"
assert_not_contains "${global_scope_out}" "project-only" "--scope global does not read project log"

explicit_scope_out="$(cd "${REPO_DIR}" && VIBEGUARD_LOG_DIR="${SCOPE_ROOT}" bash "${SCRIPT}" --scope project --log-file "${TMP_DIR}/explicit-events.jsonl" 7 2>&1)"
assert_contains "${explicit_scope_out}" "explicit-only" "--log-file wins over scope resolution"
assert_not_contains "${explicit_scope_out}" "project-only" "--log-file output does not include project data"

MISSING_SCOPE_ROOT="${TMP_DIR}/missing-scope"
mkdir -p "${MISSING_SCOPE_ROOT}"
cp "${SCOPE_ROOT}/events.jsonl" "${MISSING_SCOPE_ROOT}/events.jsonl"
missing_scope_out="$(cd "${REPO_DIR}" && VIBEGUARD_LOG_DIR="${MISSING_SCOPE_ROOT}" bash "${SCRIPT}" 7 2>&1 || true)"
assert_contains "${missing_scope_out}" "No log data" "Missing project log reports no data"
assert_contains "${missing_scope_out}" "/projects/" "Missing project log reports the project log path"
assert_not_contains "${missing_scope_out}" "global-only" "Missing project log does not fall back to global data"

header "Malformed UTF-8 and broken JSON lines are tolerated"
mkdir -p "${TMP_DIR}/log"
python3 - "${TMP_DIR}/log/events.jsonl" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone

path = sys.argv[1]
now = datetime.now(timezone.utc)

good_events = [
    {
        "ts": (now - timedelta(days=1)).isoformat().replace("+00:00", "Z"),
        "session": "s1",
        "hook": "pre-bash-guard",
        "tool": "Bash",
        "decision": "pass",
        "reason": "",
        "detail": "cargo check",
    },
    {
        "ts": (now - timedelta(hours=3)).isoformat().replace("+00:00", "Z"),
        "session": "s2",
        "hook": "post-edit-guard",
        "tool": "Edit",
        "decision": "warn",
        "reason": "warned once",
        "detail": "src/lib.rs",
    },
]

recoverable_bad_utf8 = (
    b'{"ts":"'
    + (now - timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ").encode("ascii")
    + b'","session":"s3","hook":"pre-bash-guard","tool":"Bash","decision":"block","reason":"bad utf8","detail":"python3 -c \\"# \xe7\\""}\n'
)

with open(path, "wb") as f:
    for event in good_events:
        f.write(json.dumps(event, ensure_ascii=False).encode("utf-8") + b"\n")
    f.write(recoverable_bad_utf8)
    f.write(b'{"ts":"broken-json"\n')
PY

stats_out="$(VIBEGUARD_LOG_DIR="${TMP_DIR}/log" bash "${SCRIPT}" --scope global 7 2>&1)"
assert_contains "${stats_out}" "VibeGuard Statistics (last 7 days)" "Title is correct"
assert_contains "${stats_out}" "Total triggers: 3 times" "Recoverable malformed UTF-8 line is included"
assert_contains "${stats_out}" "Interception (block): 1 times" "Block count includes recovered malformed line"
assert_contains "${stats_out}" "Warning: 1 times" "Warn count is correct"
assert_contains "${stats_out}" "pre-bash-guard: 2 times" "Hook aggregation remains correct"
assert_contains "${stats_out}" "post-edit-guard: 1 times" "Secondary hook aggregation remains correct"

header "Legacy stats analyses are preserved"
mkdir -p "${TMP_DIR}/legacy-sections-log"
python3 - "${TMP_DIR}/legacy-sections-log/events.jsonl" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone

path = sys.argv[1]
base = datetime.now(timezone.utc) - timedelta(days=1)

events = [
    {
        "ts": base.replace(hour=10, minute=0, second=0, microsecond=0).isoformat().replace("+00:00", "Z"),
        "session": "session-a",
        "hook": "pre-bash-guard",
        "tool": "Bash",
        "decision": "warn",
        "reason": "non-standard markdown",
        "detail": "notes.md",
        "cli": "codex",
    },
    {
        "ts": base.replace(hour=11, minute=0, second=0, microsecond=0).isoformat().replace("+00:00", "Z"),
        "session": "session-a",
        "hook": "pre-bash-guard",
        "tool": "Bash",
        "decision": "pass",
        "reason": "",
        "detail": "src/main.rs",
        "cli": "codex",
    },
    {
        "ts": base.replace(hour=20, minute=0, second=0, microsecond=0).isoformat().replace("+00:00", "Z"),
        "session": "session-b",
        "hook": "post-edit-guard",
        "tool": "Edit",
        "decision": "block",
        "reason": "U-16 block",
        "detail": "src/lib.rs",
        "cli": "claude",
    },
    {
        "ts": base.replace(hour=21, minute=0, second=0, microsecond=0).isoformat().replace("+00:00", "Z"),
        "session": "session-b",
        "hook": "post-edit-guard",
        "tool": "Edit",
        "decision": "warn",
        "reason": "needs review",
        "detail": "README.md",
        "cli": "claude",
    },
]

with open(path, "w", encoding="utf-8") as f:
    for event in events:
        f.write(json.dumps(event) + "\n")
PY

legacy_sections_out="$(VIBEGUARD_LOG_DIR="${TMP_DIR}/legacy-sections-log" bash "${SCRIPT}" --scope global 7 2>&1)"
assert_contains "${legacy_sections_out}" "== Warn compliance rate analysis ==" "Warn compliance section is preserved"
assert_contains "${legacy_sections_out}" "pre-bash-guard: warn=1 pass=1 compliance rate=50% [LOW]" "Warn compliance computes pass ratio"
assert_contains "${legacy_sections_out}" "Distributed by file type:" "File type section is preserved"
assert_contains "${legacy_sections_out}" ".rs: 2 times" "File type distribution counts details"
assert_contains "${legacy_sections_out}" "Distributed by time period:" "Time period section is preserved"
assert_contains "${legacy_sections_out}" "working time (09-18): 2 times (50%)" "Working-hour distribution is computed"
assert_contains "${legacy_sections_out}" "== Performance analysis ==" "Performance section is preserved"
assert_contains "${legacy_sections_out}" "Total number of sessions: 2" "Session count is preserved"
assert_contains "${legacy_sections_out}" "Average triggers per session: 2.0 times" "Average trigger count is preserved"
assert_contains "${legacy_sections_out}" "Deterministic node estimated savings: ~2K tokens" "Token savings estimate is preserved"
assert_contains "${legacy_sections_out}" "Conversations with the most questions Top 3:" "Problem sessions section is preserved"
assert_contains "${legacy_sections_out}" "session-b: 2 issues / 2 triggers" "Problem sessions are ranked"

header "Legacy wrapper reads beyond observe default limit"
mkdir -p "${TMP_DIR}/large-log"
python3 - "${TMP_DIR}/large-log/events.jsonl" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone

path = sys.argv[1]
now = datetime.now(timezone.utc) - timedelta(hours=1)

with open(path, "w", encoding="utf-8") as f:
    first = {
        "ts": now.isoformat().replace("+00:00", "Z"),
        "session": "first",
        "hook": "first-hook",
        "tool": "Bash",
        "decision": "warn",
        "reason": "first event",
        "detail": "first event",
    }
    f.write(json.dumps(first) + "\n")
    for index in range(5000):
        event = {
            "ts": (now + timedelta(seconds=index + 1)).isoformat().replace("+00:00", "Z"),
            "session": f"bulk-{index}",
            "hook": "bulk-hook",
            "tool": "Bash",
            "decision": "pass",
            "reason": "",
            "detail": "bulk event",
        }
        f.write(json.dumps(event) + "\n")
PY

large_stats_out="$(bash "${SCRIPT}" --log-file "${TMP_DIR}/large-log/events.jsonl" 7 2>&1)"
assert_contains "${large_stats_out}" "Total triggers: 5001 times" "Stats wrapper preserves events beyond observe default limit"
assert_contains "${large_stats_out}" "first-hook: 1 times" "Stats wrapper includes earliest event beyond default limit"

header "Prometheus exporter uses low-cardinality labels"
EXPORTER="${REPO_DIR}/scripts/metrics/metrics-exporter.sh"

mkdir -p "${TMP_DIR}/prom-log"
python3 - "${TMP_DIR}/prom-log/events.jsonl" <<'PY'
import json
import sys

path = sys.argv[1]
events = [
    {
        "ts": "2026-05-31T00:00:00Z",
        "session": "secret-session",
        "hook": "post-edit-guard",
        "tool": "Edit",
        "decision": "warn",
        "reason": "U-16 block for customer@example.com command cargo test -- --ignored",
        "detail": "Edit /var/tmp/vibeguard/project/src/private_token.rs",
        "duration_ms": 250,
    }
]
with open(path, "w", encoding="utf-8") as f:
    for event in events:
        f.write(json.dumps(event) + "\n")
PY

prom_out="$(VIBEGUARD_LOG_DIR="${TMP_DIR}/prom-log" VIBEGUARD_RUNTIME="${RUNTIME}" bash "${EXPORTER}" --since all 2>&1)"
assert_contains "${prom_out}" "vibeguard_event_total" "Prometheus event counter is emitted"
assert_contains "${prom_out}" 'vibeguard_tool_total{tool="Edit"} 1' "Legacy tool counter is preserved"
assert_contains "${prom_out}" 'rule_id="U-16"' "Rule id is derived safely"
assert_contains "${prom_out}" 'reason_code="rule_violation"' "Reason code is derived safely"
assert_contains "${prom_out}" 'file_ext="rs"' "File extension is derived safely"
assert_contains "${prom_out}" "vibeguard_hook_duration_seconds_sum" "Duration summary is emitted"
assert_not_contains "${prom_out}" "secret-session" "Session id is not exported as a label"
assert_not_contains "${prom_out}" "customer@example.com" "Raw reason content is absent"
assert_not_contains "${prom_out}" "cargo test -- --ignored" "Raw command-like reason content is absent"
assert_not_contains "${prom_out}" "/var/tmp/vibeguard" "Full path detail is absent"
assert_not_contains "${prom_out}" "private_token" "Raw filename detail is absent"

prom_file="${TMP_DIR}/metrics.prom"
file_msg="$(VIBEGUARD_LOG_DIR="${TMP_DIR}/prom-log" VIBEGUARD_RUNTIME="${RUNTIME}" bash "${EXPORTER}" --since all --file "${prom_file}" 2>&1)"
assert_contains "${file_msg}" "Indicator written: ${prom_file}" "Exporter --file still writes textfile output"
assert_contains "$(cat "${prom_file}")" "vibeguard_guard_violation_total" "Textfile output contains metrics"

project_root="${TMP_DIR}/prom-project"
project_log_dir="${TMP_DIR}/prom-project-log/projects/abcdef12"
mkdir -p "${project_root}" "${project_log_dir}"
printf '%s\n' "${project_root}" > "${project_log_dir}/.project-root"
python3 - "${project_log_dir}/events.jsonl" <<'PY'
import json
import sys

path = sys.argv[1]
event = {
    "ts": "2026-05-31T00:00:00Z",
    "hook": "pre-bash-guard",
    "tool": "Bash",
    "decision": "block",
    "reason": "force push denied",
    "detail": "git push --force",
}
with open(path, "w", encoding="utf-8") as f:
    f.write(json.dumps(event) + "\n")
PY

project_prom_out="$(VIBEGUARD_LOG_DIR="${TMP_DIR}/prom-project-log" VIBEGUARD_RUNTIME="${RUNTIME}" bash "${EXPORTER}" --since all --project "${project_root}" 2>&1)"
assert_contains "${project_prom_out}" "vibeguard_events_total 1" "Exporter --project reads mapped project log"
assert_contains "${project_prom_out}" 'vibeguard_tool_total{tool="Bash"} 1' "Exporter --project forwards project to runtime"
assert_contains "${project_prom_out}" 'reason_code="dangerous_command"' "Project exporter output preserves derived labels"
assert_not_contains "${project_prom_out}" "git push --force" "Project exporter output avoids raw command detail"

missing_prom_file="${TMP_DIR}/missing.prom"
set +e
missing_export_out="$(VIBEGUARD_LOG_DIR="${TMP_DIR}/prom-missing-log" VIBEGUARD_RUNTIME="${RUNTIME}" bash "${EXPORTER}" --since all --file "${missing_prom_file}" 2>&1)"
missing_export_status=$?
set -e
assert_cmd "Exporter missing log exits nonzero" test "${missing_export_status}" -ne 0
assert_contains "${missing_export_out}" "Log file does not exist" "Exporter missing log reports the missing log"
assert_cmd "Exporter missing log does not create textfile output" test ! -e "${missing_prom_file}"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

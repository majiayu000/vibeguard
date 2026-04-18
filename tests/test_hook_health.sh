#!/usr/bin/env bash
# VibeGuard hook-health regression testing
#
# Usage: bash tests/test_hook_health.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${REPO_DIR}/scripts/hook-health.sh"

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

assert_exit_nonzero() {
  local code="$1" desc="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$code" -ne 0 ]]; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected non-zero exit)"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

header "No log file"
no_log_out="$(VIBEGUARD_LOG_DIR="${TMP_DIR}/missing" bash "${SCRIPT}" 2>&1 || true)"
assert_contains "${no_log_out}" "No log data" "Prompt when logs are missing"

header "Health snapshot of the last 24 hours"
mkdir -p "${TMP_DIR}/log"
python3 - "${TMP_DIR}/log/events.jsonl" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone

path = sys.argv[1]
now = datetime.now(timezone.utc)

events = [
    {
        "ts": (now - timedelta(hours=1)).isoformat().replace("+00:00", "Z"),
        "session": "s1",
        "hook": "pre-bash-guard",
        "tool": "Bash",
        "decision": "pass",
        "reason": "",
        "detail": "cargo check",
    },
    {
        "ts": (now - timedelta(hours=2)).isoformat().replace("+00:00", "Z"),
        "session": "s2",
        "hook": "stop-guard",
        "tool": "Stop",
        "decision": "gate",
        "reason": "uncommitted source changes",
        "detail": "src/main.rs",
    },
    {
        "ts": (now - timedelta(hours=3)).isoformat().replace("+00:00", "Z"),
        "session": "s3",
        "hook": "pre-bash-guard",
        "tool": "Bash",
        "decision": "warn",
        "reason": "Non-standard .md file",
        "detail": "echo hi > notes.md",
    },
    {
        "ts": (now - timedelta(minutes=30)).isoformat().replace("+00:00", "Z"),
        "session": "s4",
        "hook": "post-edit-guard",
        "tool": "Edit",
        "decision": "correction",
        "reason": "replace any with concrete type",
        "detail": "src/lib.rs",
    },
    {
        "ts": (now - timedelta(hours=30)).isoformat().replace("+00:00", "Z"),
        "session": "old",
        "hook": "pre-commit-guard",
        "tool": "git-commit",
        "decision": "block",
        "reason": "old event out of window",
        "detail": "",
    },
]

with open(path, "w", encoding="utf-8") as f:
    for event in events:
        f.write(json.dumps(event, ensure_ascii=False) + "\n")
PY

health_out="$(VIBEGUARD_LOG_DIR="${TMP_DIR}/log" bash "${SCRIPT}" 24 2>&1)"
assert_contains "${health_out}" "VibeGuard Hook Health (last 24 hours)" "Title is correct"
assert_contains "${health_out}" "Total triggers: 4" "Filter out events within 24 hours"
assert_contains "${health_out}" "Pass: 1" "Pass statistics are correct"
assert_contains "${health_out}" "Risk (non-pass): 3" "Risk statistics are correct"
assert_contains "${health_out}" "Risk rate: 75.0%" "Risk rate calculation is correct"
assert_contains "${health_out}" "Risk Hook Top 5:" "Output risk hook ranking"
assert_contains "${health_out}" "Top 10 recent risk events:" "Output the latest risk events"
assert_contains "${health_out}" "stop-guard | gate" "Risk event contains gate"

header "Malformed UTF-8 and broken JSON lines are tolerated"
python3 - "${TMP_DIR}/log/events-malformed.jsonl" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone

path = sys.argv[1]
now = datetime.now(timezone.utc)

good_events = [
    {
        "ts": (now - timedelta(hours=1)).isoformat().replace("+00:00", "Z"),
        "session": "utf8-1",
        "hook": "pre-bash-guard",
        "tool": "Bash",
        "decision": "pass",
        "reason": "",
        "detail": "cargo check",
    },
    {
        "ts": (now - timedelta(minutes=30)).isoformat().replace("+00:00", "Z"),
        "session": "utf8-2",
        "hook": "post-edit-guard",
        "tool": "Edit",
        "decision": "warn",
        "reason": "contains replacement char",
        "detail": "src/lib.rs",
    },
]

recoverable_bad_utf8 = (
    b'{"ts":"'
    + (now - timedelta(minutes=10)).strftime("%Y-%m-%dT%H:%M:%SZ").encode("ascii")
    + b'","session":"utf8-3","hook":"pre-bash-guard","tool":"Bash","decision":"warn","reason":"bad utf8","detail":"python3 -c \\"# \xe7\\""}\n'
)

with open(path, "wb") as f:
    f.write(recoverable_bad_utf8)
    for event in good_events:
        f.write(json.dumps(event, ensure_ascii=False).encode("utf-8") + b"\n")
    f.write(b'{"ts":"broken-json"\n')
PY

cp "${TMP_DIR}/log/events-malformed.jsonl" "${TMP_DIR}/log/events.jsonl"
malformed_out="$(VIBEGUARD_LOG_DIR="${TMP_DIR}/log" bash "${SCRIPT}" 24 2>&1)"
assert_contains "${malformed_out}" "Total triggers: 3" "Recoverable malformed UTF-8 line is counted and broken JSON line is skipped"
assert_contains "${malformed_out}" "Risk (non-pass): 2" "Malformed UTF-8 line still contributes to decision counts"
assert_contains "${malformed_out}" "pre-bash-guard: 1" "Recovered line participates in non-pass hook aggregation"

header "illegal parameter"
set +e
bad_arg_out="$(VIBEGUARD_LOG_DIR="${TMP_DIR}/log" bash "${SCRIPT}" abc 2>&1)"
bad_arg_code=$?
set -e
assert_exit_nonzero "${bad_arg_code}" "Illegal argument returns non-zero"
assert_contains "${bad_arg_out}" "The argument must be a positive integer number of hours" "Illegal parameter error message"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

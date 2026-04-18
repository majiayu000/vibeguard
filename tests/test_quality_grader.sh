#!/usr/bin/env bash
# VibeGuard quality-grader regression testing
#
# Usage: bash tests/test_quality_grader.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${REPO_DIR}/scripts/quality-grader.sh"

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

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

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
        "session": "q1",
        "hook": "pre-bash-guard",
        "tool": "Bash",
        "decision": "pass",
        "reason": "",
        "detail": "cargo check",
        "duration_ms": 200,
    },
    {
        "ts": (now - timedelta(hours=6)).isoformat().replace("+00:00", "Z"),
        "session": "q2",
        "hook": "post-edit-guard",
        "tool": "Edit",
        "decision": "warn",
        "reason": "warned once",
        "detail": "src/lib.rs",
        "duration_ms": 800,
    },
]

recoverable_bad_utf8 = (
    b'{"ts":"'
    + (now - timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ").encode("ascii")
    + b'","session":"q3","hook":"pre-bash-guard","tool":"Bash","decision":"block","reason":"bad utf8","detail":"python3 -c \\"# \xe7\\"","duration_ms":150}\n'
)

with open(path, "wb") as f:
    f.write(recoverable_bad_utf8)
    for event in good_events:
        f.write(json.dumps(event, ensure_ascii=False).encode("utf-8") + b"\n")
    f.write(b'{"ts":"broken-json"\n')
PY

grader_out="$(VIBEGUARD_LOG_DIR="${TMP_DIR}/log" bash "${SCRIPT}" 7 --json 2>&1)"
assert_contains "${grader_out}" '"events_analyzed": 3' "Recoverable malformed UTF-8 line is included in grading"
assert_contains "${grader_out}" '"grade": "' "JSON output still returns a grade"
assert_contains "${grader_out}" '"security":' "Security metric is present"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

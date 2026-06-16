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
  if grep -qF -- "$expected" <<< "$output"; then
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
  if grep -qF -- "$forbidden" <<< "$output"; then
    red "$desc (must not contain: $forbidden)"
    FAIL=$((FAIL + 1))
  else
    green "$desc"
    PASS=$((PASS + 1))
  fi
}

assert_line_before() {
  local output="$1" first="$2" second="$3" desc="$4"
  local first_line second_line
  TOTAL=$((TOTAL + 1))
  first_line="$(grep -nF -- "$first" <<< "$output" | head -n 1 | cut -d: -f1 || true)"
  second_line="$(grep -nF -- "$second" <<< "$output" | head -n 1 | cut -d: -f1 || true)"
  if [[ -n "${first_line}" && -n "${second_line}" && "${first_line}" -lt "${second_line}" ]]; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc"
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

header "build"
assert_cmd "vibeguard-runtime builds for health wrapper" \
  cargo build --manifest-path "${REPO_DIR}/vibeguard-runtime/Cargo.toml" --quiet

header "Runtime support probe"
health_only_runtime="${TMP_DIR}/health-only-runtime"
cat > "${health_only_runtime}" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "observe" && "${2:-}" == "health" ]]; then
  printf 'fake health\n'
  exit 0
fi
exit 2
SH
chmod +x "${health_only_runtime}"
assert_cmd "Health wrapper accepts runtime with observe health support" \
  env VIBEGUARD_RUNTIME="${health_only_runtime}" bash "${SCRIPT}" --log-file /dev/null 24

summary_only_runtime="${TMP_DIR}/summary-only-runtime"
cat > "${summary_only_runtime}" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "observe" && "${2:-}" == "summary" ]]; then
  printf 'fake stats\n'
  exit 0
fi
exit 2
SH
chmod +x "${summary_only_runtime}"
health_probe_out="$(VIBEGUARD_RUNTIME="${summary_only_runtime}" bash "${SCRIPT}" --log-file /dev/null 24 2>&1 || true)"
assert_contains "${health_probe_out}" "VIBEGUARD_RUNTIME does not support required capability: observe_health" "Health wrapper rejects runtime without observe health support"

header "No log file"
no_log_out="$(VIBEGUARD_LOG_DIR="${TMP_DIR}/missing" bash "${SCRIPT}" 2>&1 || true)"
assert_contains "${no_log_out}" "No log data" "Prompt when logs are missing"

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
        "ts": (now - timedelta(minutes=5)).isoformat().replace("+00:00", "Z"),
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

project_scope_out="$(cd "${REPO_DIR}" && VIBEGUARD_LOG_DIR="${SCOPE_ROOT}" bash "${SCRIPT}" 24 2>&1)"
assert_contains "${project_scope_out}" "project-only" "Default scope reads current project log"
assert_not_contains "${project_scope_out}" "global-only" "Default project scope does not read global log"

global_scope_out="$(cd "${REPO_DIR}" && VIBEGUARD_LOG_DIR="${SCOPE_ROOT}" bash "${SCRIPT}" --scope global 24 2>&1)"
assert_contains "${global_scope_out}" "global-only" "--scope global reads global log"
assert_not_contains "${global_scope_out}" "project-only" "--scope global does not read project log"

explicit_scope_out="$(cd "${REPO_DIR}" && VIBEGUARD_LOG_DIR="${SCOPE_ROOT}" bash "${SCRIPT}" --scope project --log-file "${TMP_DIR}/explicit-events.jsonl" 24 2>&1)"
assert_contains "${explicit_scope_out}" "explicit-only" "--log-file wins over scope resolution"
assert_not_contains "${explicit_scope_out}" "project-only" "--log-file output does not include project data"

MISSING_SCOPE_ROOT="${TMP_DIR}/missing-scope"
mkdir -p "${MISSING_SCOPE_ROOT}"
cp "${SCOPE_ROOT}/events.jsonl" "${MISSING_SCOPE_ROOT}/events.jsonl"
missing_scope_out="$(cd "${REPO_DIR}" && VIBEGUARD_LOG_DIR="${MISSING_SCOPE_ROOT}" bash "${SCRIPT}" 24 2>&1 || true)"
assert_contains "${missing_scope_out}" "No log data" "Missing project log reports no data"
assert_contains "${missing_scope_out}" "/projects/" "Missing project log reports the project log path"
assert_not_contains "${missing_scope_out}" "global-only" "Missing project log does not fall back to global data"

header "Health snapshot of the last 24 hours"
mkdir -p "${TMP_DIR}/log"
python3 - "${TMP_DIR}/log/events.jsonl" "${TMP_DIR}/log/expected-range.txt" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone

path, expected_range_path = sys.argv[1:3]
now = datetime.now(timezone.utc)
oldest_in_window = (now - timedelta(hours=3)).isoformat().replace("+00:00", "Z")
latest_in_window = (now - timedelta(minutes=30)).isoformat().replace("+00:00", "Z")
recent_utc = now - timedelta(minutes=40)
older_offset = (recent_utc - timedelta(minutes=15)).astimezone(timezone(timedelta(hours=1)))

events = [
    {
        "ts": (now - timedelta(hours=1)).isoformat().replace("+00:00", "Z"),
        "session": "s1",
        "hook": "pre-bash-guard",
        "tool": "Bash",
        "decision": "pass",
        "reason": "",
        "detail": "cargo check",
        "cli": "claude",
        "client": "claude",
    },
    {
        "ts": (now - timedelta(hours=2)).isoformat().replace("+00:00", "Z"),
        "session": "s2",
        "hook": "stop-guard",
        "tool": "Stop",
        "decision": "gate",
        "reason": "uncommitted source changes",
        "detail": "src/main.rs",
        "cli": "codex",
        "client": "codex",
    },
    {
        "ts": oldest_in_window,
        "session": "s3",
        "hook": "pre-bash-guard",
        "tool": "Bash",
        "decision": "warn",
        "reason": "Non-standard .md file",
        "detail": "echo hi > notes.md",
    },
    {
        "ts": latest_in_window,
        "session": "s4",
        "hook": "post-edit-guard",
        "tool": "Edit",
        "decision": "correction",
        "reason": "replace any with concrete type",
        "detail": "src/lib.rs",
    },
    {
        "ts": recent_utc.isoformat().replace("+00:00", "Z"),
        "session": "offset-newer",
        "hook": "offset-newer-hook",
        "tool": "Edit",
        "decision": "warn",
        "reason": "newer instant",
        "detail": "newer.rs",
    },
    {
        "ts": older_offset.isoformat(),
        "session": "offset-older",
        "hook": "offset-older-hook",
        "tool": "Edit",
        "decision": "block",
        "reason": "older offset instant",
        "detail": "older.rs",
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
with open(expected_range_path, "w", encoding="utf-8") as f:
    f.write(oldest_in_window + "\n")
    f.write(latest_in_window + "\n")
    f.write(older_offset.isoformat() + "\n")
PY

health_out="$(VIBEGUARD_LOG_DIR="${TMP_DIR}/log" bash "${SCRIPT}" --scope global 24 2>&1)"
expected_first_ts="$(sed -n '1p' "${TMP_DIR}/log/expected-range.txt")"
expected_last_ts="$(sed -n '2p' "${TMP_DIR}/log/expected-range.txt")"
lexically_late_offset_ts="$(sed -n '3p' "${TMP_DIR}/log/expected-range.txt")"
assert_contains "${health_out}" "VibeGuard Hook Health (last 24 hours)" "Title is correct"
assert_contains "${health_out}" "Time range: ${expected_first_ts} ~ ${expected_last_ts}" "Time range is ordered by parsed timestamp"
assert_not_contains "${health_out}" "Time range: ${expected_first_ts} ~ ${lexically_late_offset_ts}" "Time range does not use lexicographic offset order"
assert_contains "${health_out}" "Total triggers: 6" "Filter out events within 24 hours"
assert_contains "${health_out}" "Pass: 1" "Pass statistics are correct"
assert_contains "${health_out}" "Risk (non-pass): 5" "Risk statistics are correct"
assert_contains "${health_out}" "Risk rate: 83.3%" "Risk rate calculation is correct"
assert_contains "${health_out}" "Client distribution:" "Output client distribution"
assert_contains "${health_out}" "claude: 1" "Client distribution includes Claude"
assert_contains "${health_out}" "codex: 1" "Client distribution includes Codex"
assert_contains "${health_out}" "Risk Hook Top 5:" "Output risk hook ranking"
assert_contains "${health_out}" "Top 10 recent risk events:" "Output the latest risk events"
assert_contains "${health_out}" "stop-guard | gate | cli=codex | client=codex" "Risk event contains caller split"
assert_line_before "${health_out}" "session=offset-newer" "session=offset-older" "Recent risk events are ordered by parsed timestamp"

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
malformed_out="$(VIBEGUARD_LOG_DIR="${TMP_DIR}/log" bash "${SCRIPT}" --scope global 24 2>&1)"
assert_contains "${malformed_out}" "Total triggers: 3" "Recoverable malformed UTF-8 line is counted and broken JSON line is skipped"
assert_contains "${malformed_out}" "Risk (non-pass): 2" "Malformed UTF-8 line still contributes to decision counts"
assert_contains "${malformed_out}" "pre-bash-guard: 1" "Recovered line participates in non-pass hook aggregation"

header "Health wrapper reads beyond observe default limit"
mkdir -p "${TMP_DIR}/large-health-log"
python3 - "${TMP_DIR}/large-health-log/events.jsonl" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone

path = sys.argv[1]
now = datetime.now(timezone.utc) - timedelta(hours=1)

with open(path, "w", encoding="utf-8") as f:
    first = {
        "ts": now.isoformat().replace("+00:00", "Z"),
        "session": "first",
        "hook": "first-health-hook",
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
            "hook": "bulk-health-hook",
            "tool": "Bash",
            "decision": "pass",
            "reason": "",
            "detail": "bulk event",
        }
        f.write(json.dumps(event) + "\n")
PY

large_health_out="$(bash "${SCRIPT}" --log-file "${TMP_DIR}/large-health-log/events.jsonl" 24 2>&1)"
assert_contains "${large_health_out}" "Total triggers: 5001" "Health wrapper preserves events beyond observe default limit"
assert_contains "${large_health_out}" "first-health-hook: 1" "Health wrapper includes earliest risk event beyond default limit"

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

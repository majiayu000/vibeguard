#!/usr/bin/env bash
# VibeGuard scheduled GC integration tests.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

PASS=0
FAIL=0
TOTAL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header(){ printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

assert_contains() {
  local output="$1" expected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$output" | grep -qF -- "$expected"; then
    green "$desc"; PASS=$((PASS + 1))
  else
    red "$desc (expected to contain: $expected)"; FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local output="$1" unexpected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if ! printf '%s' "$output" | grep -qF -- "$unexpected"; then
    green "$desc"; PASS=$((PASS + 1))
  else
    red "$desc (unexpectedly contains: $unexpected)"; FAIL=$((FAIL + 1))
  fi
}

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

header "gc-scheduled.py helpers compile"
assert_cmd "scheduled GC Python helpers compile" python3 -m py_compile \
  scripts/gc/session_metrics_cleanup.py \
  scripts/gc/learn_digest.py \
  scripts/gc/reflection_digest.py

header "gc-scheduled.sh orchestrates helpers"

log_dir="${TMP_ROOT}/logs"
project_dir="${log_dir}/projects/abc123"
mkdir -p "$project_dir"
today="$(date -u '+%Y-%m-%dT00:00:00Z')"

cat > "${project_dir}/session-metrics.jsonl" <<EOF
{"ts":"2020-01-01T00:00:00Z","event_count":1,"decisions":{"warn":1},"hooks":{"old":1},"top_edited_files":{"old.py":1}}
{"ts":"${today}","event_count":5,"decisions":{"pass":3,"warn":2},"hooks":{"post-edit-guard":2},"top_edited_files":{"src/app.py":2},"warn_ratio":0.4}
EOF
printf '%s\n' "$TMP_ROOT/project" > "${project_dir}/.project-root"
mkdir -p "$TMP_ROOT/project"

cfg="${TMP_ROOT}/.vibeguard.json"
cat > "$cfg" <<'JSON'
{
  "gc": {
    "session_metrics_retain_days": 30,
    "learning_window_days": 7,
    "gc_log_max_kb": 1024
  }
}
JSON

VIBEGUARD_LOG_DIR="$log_dir" VIBEGUARD_PROJECT_CONFIG="$cfg" bash scripts/gc/gc-scheduled.sh

gc_log="$(cat "${log_dir}/gc-cron.log")"
metrics_after="$(cat "${project_dir}/session-metrics.jsonl")"
reflection="$(cat "${log_dir}/reflection-digest.md")"

assert_contains "$gc_log" "--- Session Metrics Cleanup ---" "scheduled GC runs metrics cleanup section"
assert_contains "$gc_log" "Clean 1 expired metrics" "scheduled GC prunes expired metrics"
assert_contains "$gc_log" "--- Regular learning" "scheduled GC runs learning digest section"
assert_contains "$gc_log" "---Session Quality Reflection" "scheduled GC runs reflection section"
assert_contains "$metrics_after" "$today" "current session metric remains"
assert_not_contains "$metrics_after" "2020-01-01" "expired session metric is removed"
assert_contains "$reflection" "VibeGuard Weekly Reflection Report" "reflection report is generated"

header "gc-scheduled.sh catch-up mode"

skip_log_before="$(wc -l < "${log_dir}/gc-cron.log" | tr -d ' ')"
VIBEGUARD_LOG_DIR="$log_dir" VIBEGUARD_PROJECT_CONFIG="$cfg" bash scripts/gc/gc-scheduled.sh --scheduled
skip_log_after="$(wc -l < "${log_dir}/gc-cron.log" | tr -d ' ')"
assert_cmd "scheduled mode skips when last success is fresh and logs are below threshold" test "$skip_log_before" = "$skip_log_after"

python3 - "${log_dir}/events.jsonl" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
with path.open("w", encoding="utf-8") as f:
    for index in range(20000):
        f.write(json.dumps({
            "ts": "2024-01-01T00:00:00Z",
            "session": "oversized",
            "hook": "pre-bash-guard",
            "tool": "Bash",
            "decision": "pass",
            "detail": "x" * 80,
            "index": index,
        }) + "\n")
    f.write(json.dumps({
        "ts": "2099-01-01T00:00:00Z",
        "session": "current",
        "hook": "pre-bash-guard",
        "tool": "Bash",
        "decision": "pass",
        "detail": "current",
    }) + "\n")
PY

VIBEGUARD_LOG_DIR="$log_dir" VIBEGUARD_PROJECT_CONFIG="$cfg" VIBEGUARD_GC_LOG_THRESHOLD_MB=1 \
  VIBEGUARD_GC_ARCHIVE_RETAIN_MONTHS=1200 \
  bash scripts/gc/gc-scheduled.sh --scheduled

assert_cmd "scheduled mode catches up when global log exceeds threshold" test -f "${log_dir}/archive/events-2024-01.jsonl.gz"
assert_contains "$(cat "${log_dir}/events.jsonl")" "current" "catch-up retains current log events"
assert_contains "$(cat "${log_dir}/gc-cron.log")" "--- Log archive ---" "catch-up records archive section"

printf '%s\n' "123" > "${log_dir}/gc-last-success"
python3 - "${log_dir}/events.jsonl" "$(date -u '+%Y-%m-01T00:00:00Z')" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
ts = sys.argv[2]
with path.open("w", encoding="utf-8") as f:
    for index in range(20000):
        f.write(json.dumps({
            "ts": ts,
            "session": "current-oversized",
            "hook": "pre-bash-guard",
            "tool": "Bash",
            "decision": "pass",
            "detail": "y" * 80,
            "index": index,
        }) + "\n")
PY

VIBEGUARD_LOG_DIR="$log_dir" VIBEGUARD_PROJECT_CONFIG="$cfg" VIBEGUARD_GC_LOG_THRESHOLD_MB=1 \
  bash scripts/gc/gc-scheduled.sh --scheduled

assert_cmd "failed scheduled GC records an attempt" test -f "${log_dir}/gc-last-attempt"
assert_contains "$(cat "${log_dir}/gc-last-success")" "123" "failed scheduled GC does not update last-success"
assert_contains "$(cat "${log_dir}/gc-cron.log")" "GC completed with errors" "failed scheduled GC is visible in cron log"

printf '\n==============================\n'
printf 'Total: %s  Pass: \033[32m%s\033[0m  Fail: \033[31m%s\033[0m\n' "$TOTAL" "$PASS" "$FAIL"
printf '==============================\n'

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi

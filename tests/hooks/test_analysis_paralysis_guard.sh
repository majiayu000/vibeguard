#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
hook_test_init

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR" "$VIBEGUARD_LOG_DIR"' EXIT

RUNTIME_BIN="${REPO_DIR}/vibeguard-runtime/target/debug/vibeguard-runtime"
cargo build --manifest-path "${REPO_DIR}/vibeguard-runtime/Cargo.toml" >/dev/null
export VIBEGUARD_RUNTIME="${RUNTIME_BIN}"

hook_no_ci_env=(
  CI=false
  GITHUB_ACTIONS=false
  TRAVIS=false
  CIRCLECI=false
  JENKINS_URL=
  GITLAB_CI=false
  TF_BUILD=false
)

make_log_dir() {
  mktemp -d "$WORK_DIR/logs.XXXXXX"
}

event_log_file() {
  local log_dir="$1" session="$2"
  VIBEGUARD_LOG_DIR="$log_dir" VIBEGUARD_SESSION_ID="$session" bash -c '
    source hooks/log.sh
    printf "%s" "$VIBEGUARD_LOG_FILE"
  '
}

seed_research_events() {
  local log_dir="$1" session="$2" count="$3" log_file
  log_file="$(event_log_file "$log_dir" "$session")"
  mkdir -p "$(dirname "$log_file")"
  python3 - "$log_file" "$session" "$count" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone

log_file, session, count = sys.argv[1], sys.argv[2], int(sys.argv[3])
now = datetime.now(timezone.utc)
with open(log_file, "w", encoding="utf-8") as fh:
    for i in range(count):
        ts = now - timedelta(seconds=count - i)
        fh.write(json.dumps({
            "ts": ts.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "session": session,
            "hook": "analysis-paralysis-guard",
            "tool": "Read",
            "decision": "pass",
            "reason": "",
            "detail": "",
        }) + "\n")
PY
}

header "analysis-paralysis guard — mutating tool reset"

bash_log="$(make_log_dir)"
bash_session="analysis-bash-reset"
seed_research_events "$bash_log" "$bash_session" 7
bash_out="$(env "${hook_no_ci_env[@]}" \
  VIBEGUARD_LOG_DIR="$bash_log" VIBEGUARD_SESSION_ID="$bash_session" VG_PARALYSIS_THRESHOLD=7 \
  bash hooks/analysis-paralysis-guard.sh <<'JSON'
{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"sed -i '' -e s/a/b/ file.txt"}}
JSON
)"
bash_events="$(cat "$(event_log_file "$bash_log" "$bash_session")")"
assert_not_contains "$bash_out" "ANALYSIS PARALYSIS" "Bash invocation resets read-only streak instead of warning"
assert_contains "$bash_events" '"tool": "Bash"' "Bash invocation is logged with the real tool"
assert_contains "$bash_events" "reset_by=Bash" "Bash reset reason is visible"

edit_log="$(make_log_dir)"
edit_session="analysis-edit-reset"
seed_research_events "$edit_log" "$edit_session" 7
edit_out="$(env "${hook_no_ci_env[@]}" \
  VIBEGUARD_LOG_DIR="$edit_log" VIBEGUARD_SESSION_ID="$edit_session" VG_PARALYSIS_THRESHOLD=7 \
  bash hooks/analysis-paralysis-guard.sh <<'JSON'
{"hook_event_name":"PostToolUse","tool_input":{"file_path":"src/lib.rs","old_string":"a","new_string":"b"}}
JSON
)"
edit_events="$(cat "$(event_log_file "$edit_log" "$edit_session")")"
assert_not_contains "$edit_out" "ANALYSIS PARALYSIS" "Edit payload without tool_name still resets read-only streak"
assert_contains "$edit_events" '"tool": "Edit"' "Edit payload is inferred from tool_input"

header "analysis-paralysis guard — W-13 triage"

read_log="$(make_log_dir)"
read_session="analysis-read-warn"
triage_file="$WORK_DIR/triage.jsonl"
seed_research_events "$read_log" "$read_session" 2
read_out="$(env "${hook_no_ci_env[@]}" \
  VIBEGUARD_LOG_DIR="$read_log" VIBEGUARD_SESSION_ID="$read_session" VG_PARALYSIS_THRESHOLD=2 \
  VIBEGUARD_TRIAGE_FILE="$triage_file" bash hooks/analysis-paralysis-guard.sh <<'JSON'
{"hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{"file_path":"README.md"}}
JSON
)"
read_events="$(cat "$(event_log_file "$read_log" "$read_session")")"
triage_out="$(python3 - "$triage_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    rows = [json.loads(line) for line in fh if line.strip()]
assert len(rows) == 1, rows
assert rows[0]["rule"] == "W-13", rows[0]
assert rows[0]["decision"] == "warn", rows[0]
print("w13-triage-ok")
PY
)"
assert_contains "$read_out" "ANALYSIS PARALYSIS" "Read streak still triggers W-13 warning"
assert_contains "$read_events" "W-13 paralysis 2x" "W-13 warning reason is logged"
assert_contains "$triage_out" "w13-triage-ok" "W-13 warning projects into triage"

hook_test_finish

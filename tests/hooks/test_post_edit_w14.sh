#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
hook_test_init

header "post-edit-guard.sh — W-14 path normalization"
# =========================================================

_w14_dir=$(mktemp -d "$REPO_DIR/.tmp-w14.XXXXXX")
_w14_file="$_w14_dir/overlap.py"
printf 'value = 1\n' > "$_w14_file"
_w14_rel="${_w14_file#$REPO_DIR/}"
_w14_project_hash=$(printf '%s' "$REPO_DIR" | shasum -a 256 2>/dev/null | cut -c1-8)
_w14_log_file="$VIBEGUARD_LOG_DIR/projects/${_w14_project_hash}/events.jsonl"
mkdir -p "$(dirname "$_w14_log_file")"

_w14_timestamp_ago() {
  python3 - "$1" <<'PY'
from datetime import datetime, timedelta, timezone
import sys

seconds = int(sys.argv[1])
print((datetime.now(timezone.utc) - timedelta(seconds=seconds)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
}

_w14_key() {
  python3 - "$1" "$2" "$3" <<'PY'
import hashlib
import os
import sys

current, peer, path = sys.argv[1:]
normalized = os.path.realpath(path)
raw = f"{len(current)}:{current}{len(peer)}:{peer}{len(normalized)}:{normalized}"
print(hashlib.sha256(raw.encode()).hexdigest())
PY
}

_w14_seed_history() {
  local target=$1
  local peer=$2
  local shown_key=${3:--}
  local shown_age=${4:-0}
  python3 - "$_w14_log_file" "$target" "$peer" "$shown_key" "$shown_age" <<'PY'
from datetime import datetime, timedelta, timezone
import json
import sys

log_file, target, peer, shown_key, shown_age = sys.argv[1:]
now = datetime.now(timezone.utc)
candidate = {
    "ts": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "hook": "post-write-guard",
    "tool": "Write",
    "decision": "pass",
    "agent": "peer-agent",
    "detail": target,
}
if peer != "__missing__":
    candidate["session"] = peer
events = [candidate]
if shown_key != "-":
    events.append({
        "ts": (now - timedelta(seconds=int(shown_age))).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "session": "current-session",
        "hook": "post-edit-guard",
        "tool": "Edit",
        "decision": "warn",
        "status": "warn",
        "agent": "codex",
        "reason": "[W-14] overlap shown session peer agent codex",
        "detail": f"{target}||w14_key={shown_key}",
    })
with open(log_file, "w", encoding="utf-8") as handle:
    for event in events:
        handle.write(json.dumps(event, separators=(",", ":")) + "\n")
PY
}

_w14_run() {
  local target=$1
  shift
  printf '{"tool_input":{"file_path":"%s","new_string":"value = 9\\n"}}' "$target" \
    | env VIBEGUARD_LOG_DIR="$VIBEGUARD_LOG_DIR" VIBEGUARD_CLI="codex" \
      VIBEGUARD_SESSION_ID="current-session" VIBEGUARD_AGENT_TYPE="codex" \
      "$@" bash hooks/post-edit-guard.sh
}

cat > "$_w14_log_file" <<EOF
{"ts":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","session":"other-session","hook":"post-write-guard","tool":"Write","decision":"pass","detail":"$_w14_file"}
EOF

_w14_result=$(
  printf '{"tool_input":{"file_path":"%s","new_string":"value = 2\\n"}}' "$_w14_rel" \
    | VIBEGUARD_LOG_DIR="$VIBEGUARD_LOG_DIR" VIBEGUARD_CLI="codex" VIBEGUARD_SESSION_ID="current-session" bash hooks/post-edit-guard.sh
)
assert_contains "$_w14_result" "[W-14]" "W-14 detects relative/absolute matches for the same file"
assert_contains "$_w14_result" 'BASE=${VIBEGUARD_WORKTREE_BASE:-${REPO}.wt}' "W-14 worktree hint reads configured base"
assert_contains "$_w14_result" 'case \"$BASE\" in /*)' "W-14 worktree hint resolves relative base against repo root"
_w14_shown_event=$(python3 -c '
import json, sys
events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
matches = [event for event in events if event.get("reason", "").startswith("[W-14] overlap shown")]
print(json.dumps(matches[-1], sort_keys=True) if matches else "")
' "$_w14_log_file")
assert_contains "$_w14_shown_event" '"decision": "warn"' "First W-14 records dedicated shown evidence"

_w14_repeat=$(
  printf '{"tool_input":{"file_path":"%s","new_string":"value = 3\\n"}}' "$_w14_file" \
    | VIBEGUARD_LOG_DIR="$VIBEGUARD_LOG_DIR" VIBEGUARD_CLI="codex" VIBEGUARD_SESSION_ID="current-session" bash hooks/post-edit-guard.sh
)
assert_not_contains "$_w14_repeat" "[W-14]" "W-14 reuses cooldown across relative and absolute forms of the same file"
_w14_suppressed_event=$(python3 -c '
import json, sys
events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
matches = [event for event in events if event.get("reason", "").startswith("[W-14] overlap suppressed cooldown")]
print(json.dumps(matches[-1], sort_keys=True) if matches else "")
' "$_w14_log_file")
assert_contains "$_w14_suppressed_event" '"decision": "pass"' "W-14 cooldown records pass telemetry"
assert_contains "$_w14_suppressed_event" '"status": "skipped"' "W-14 cooldown records skipped status"
assert_exit_zero "W-14 cooldown records a complete opaque key" python3 -c '
import json, re, sys
event = json.loads(sys.argv[1])
raise SystemExit(0 if re.search(r"\\|\\|w14_key=[0-9a-f]{64}$", event.get("detail", "")) else 1)
' "$_w14_suppressed_event"

for _ in {1..801}; do printf 'value = 1\n'; done > "$_w14_file"
_w14_mixed=$(
  printf '{"tool_input":{"file_path":"%s","new_string":"value = 4\\n"}}' "$_w14_rel" \
    | VIBEGUARD_LOG_DIR="$VIBEGUARD_LOG_DIR" VIBEGUARD_CLI="codex" VIBEGUARD_SESSION_ID="current-session" bash hooks/post-edit-guard.sh
)
assert_not_contains "$_w14_mixed" "[W-14]" "W-14 cooldown does not renew from suppressed telemetry"
assert_contains "$_w14_mixed" "[U-16]" "W-14 cooldown preserves other post-edit warnings"

_w14_disabled=$(
  printf '{"tool_input":{"file_path":"%s","new_string":"value = 5\\n"}}' "$_w14_rel" \
    | VIBEGUARD_LOG_DIR="$VIBEGUARD_LOG_DIR" VIBEGUARD_CLI="codex" VIBEGUARD_SESSION_ID="current-session" VIBEGUARD_W14_COOLDOWN_SECONDS=0 bash hooks/post-edit-guard.sh
)
assert_contains "$_w14_disabled" "[W-14]" "W-14 cooldown value zero restores visible warnings"

printf 'value = 1\n' > "$_w14_file"
_w14_boundary_key=$(_w14_key "current-session" "boundary-peer" "$_w14_file")
_w14_seed_history "$_w14_file" "boundary-peer" "$_w14_boundary_key" 3600
_w14_boundary=$(_w14_run "$_w14_file")
assert_contains "$_w14_boundary" "[W-14]" "W-14 exact cooldown boundary fails open to a visible warning"

_w14_other_file="$_w14_dir/other.py"
printf 'value = 1\n' > "$_w14_other_file"
_w14_wrong_file_key=$(_w14_key "current-session" "other-session" "$_w14_file")
_w14_seed_history "$_w14_other_file" "other-session" "$_w14_wrong_file_key" 0
_w14_other_file_result=$(_w14_run "$_w14_other_file")
assert_contains "$_w14_other_file_result" "[W-14]" "W-14 does not share cooldown across normalized files"

_w14_wrong_peer_key=$(_w14_key "current-session" "first-peer" "$_w14_file")
_w14_seed_history "$_w14_file" "second-peer" "$_w14_wrong_peer_key" 0
_w14_other_peer=$(_w14_run "$_w14_file")
assert_contains "$_w14_other_peer" "[W-14]" "W-14 does not share cooldown across peer sessions"

_w14_reverse_key=$(_w14_key "reverse-peer" "current-session" "$_w14_file")
_w14_seed_history "$_w14_file" "reverse-peer" "$_w14_reverse_key" 0
_w14_reverse=$(_w14_run "$_w14_file")
assert_contains "$_w14_reverse" "[W-14]" "W-14 keeps current and peer session order directed"

_w14_seed_history "$_w14_file" "unknown"
_w14_unknown=$(_w14_run "$_w14_file")
assert_contains "$_w14_unknown" "[W-14]" "W-14 unknown peer session fails open"

_w14_seed_history "$_w14_file" "__missing__"
_w14_missing=$(_w14_run "$_w14_file")
assert_contains "$_w14_missing" "[W-14]" "W-14 missing peer session fails open"

_w14_seed_history "$_w14_file" "bad-history-peer"
printf 'not-json\n' >> "$_w14_log_file"
_w14_bad_history=$(_w14_run "$_w14_file")
assert_contains "$_w14_bad_history" "VG-INTERNAL-HISTORY-READ" "Malformed history reports the history read failure"
assert_contains "$_w14_bad_history" "malformed post-edit history JSONL at line 2" "Malformed history preserves the parse failure detail"
assert_not_contains "$_w14_bad_history" "[W-14]" "Malformed history does not fabricate a W-14 finding"

_w14_long_dir="$_w14_dir"
for _w14_component_index in {1..8}; do
  _w14_long_dir="$_w14_long_dir/$(printf 'x%.0s' {1..100})$_w14_component_index"
done
mkdir -p "$_w14_long_dir"
_w14_long_file="$_w14_long_dir/long.py"
printf 'value = 1\n' > "$_w14_long_file"
_w14_seed_history "$_w14_long_file" "long-path-peer"
_w14_long_result=$(_w14_run "$_w14_long_file")
assert_contains "$_w14_long_result" "[W-14]" "W-14 long-path candidate remains visible"
assert_exit_zero "W-14 shown evidence preserves a long file path and complete key" python3 - "$_w14_log_file" "$_w14_long_file" <<'PY'
import json
import re
import sys

events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
shown = [event for event in events if event.get("reason", "").startswith("[W-14] overlap shown")]
detail = shown[-1].get("detail", "") if shown else ""
path, separator, key = detail.partition("||w14_key=")
raise SystemExit(0 if path == sys.argv[2] and separator and re.fullmatch(r"[0-9a-f]{64}", key) else 1)
PY

_w14_append_key=$(_w14_key "current-session" "append-peer" "$_w14_file")
_w14_seed_history "$_w14_file" "append-peer" "$_w14_append_key" 0
mkdir -p "${_w14_log_file}.lock.d"
printf 'held\n' > "${_w14_log_file}.lock.d/owner"
_w14_append_failure=$(_w14_run "$_w14_file" \
  VIBEGUARD_LOG_LOCK_ATTEMPTS=1 \
  VIBEGUARD_LOG_LOCK_SLEEP_SECONDS=0 \
  VIBEGUARD_LOG_LOCK_STALE_SECONDS=3600 2>&1)
rm -rf "${_w14_log_file}.lock.d"
assert_contains "$_w14_append_failure" "[W-14]" "W-14 telemetry append failure preserves the visible warning"
assert_contains "$_w14_append_failure" "W-14 suppressed telemetry append failed" "W-14 telemetry append failure reports its root cause"
assert_contains "$_w14_append_failure" "VG-INTERNAL-LOG-APPEND" "W-14 final event append failure reports hook diagnostics"

rm -rf "$_w14_dir"

hook_test_finish

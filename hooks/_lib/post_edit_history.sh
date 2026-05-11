#!/usr/bin/env bash
# Event-log-backed history detectors for post-edit-guard.sh.

vg_post_edit_count_build_failures() {
  local project_root
  project_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  tail -200 "$VIBEGUARD_LOG_FILE" 2>/dev/null \
    | if [[ -n "$_VG_HELPER" ]]; then
        "$_VG_HELPER" build-fails "$VIBEGUARD_SESSION_ID" "$project_root"
      else
        VG_SESSION="$VIBEGUARD_SESSION_ID" VG_PROJECT="$project_root" VG_EVENT_LOG_LIB="$VG_EVENT_LOG_LIB" python3 -c '
import sys, os
sys.path.insert(0, os.environ["VG_EVENT_LOG_LIB"])
from event_log import iter_events_from_stream

session = os.environ.get("VG_SESSION", "")
project = os.environ.get("VG_PROJECT", "")
prefix = project.rstrip("/") + "/" if project else ""
count = 0
events = list(iter_events_from_stream(sys.stdin.buffer))
for e in reversed(events):
    if e.get("hook") != "post-build-check" or e.get("session") != session:
        continue
    detail = e.get("detail", "") or ""
    if prefix and detail and not detail.startswith(prefix):
        continue
    if e.get("decision") == "pass":
        break
    if e.get("decision") in {"warn", "escalate"}:
        count += 1
print(count)
'
      fi 2>/dev/null | tr -d '[:space:]' || echo "0"
}

vg_post_edit_detect_churn() {
  local churn_count build_fail_count
  churn_count=$(tail -500 "$VIBEGUARD_LOG_FILE" 2>/dev/null \
    | if [[ -n "$_VG_HELPER" ]]; then
        "$_VG_HELPER" churn-count "$VIBEGUARD_SESSION_ID" "$FILE_PATH"
      else
        VG_FILE_PATH="$FILE_PATH" VG_SESSION="$VIBEGUARD_SESSION_ID" VG_EVENT_LOG_LIB="$VG_EVENT_LOG_LIB" python3 -c '
import sys, os
sys.path.insert(0, os.environ["VG_EVENT_LOG_LIB"])
from event_log import iter_events_from_stream

file_path = os.environ.get("VG_FILE_PATH", "")
session = os.environ.get("VG_SESSION", "")
count = 0
for e in iter_events_from_stream(sys.stdin.buffer):
    if e.get("session") == session and e.get("tool") == "Edit" and file_path in e.get("detail", ""):
        count += 1
print(count)
'
      fi 2>/dev/null | tr -d '[:space:]' || echo "0")
  churn_count="${churn_count:-0}"
  build_fail_count="0"

  if [[ "$churn_count" -ge 20 ]]; then
    build_fail_count="$(vg_post_edit_count_build_failures)"
    build_fail_count="${build_fail_count:-0}"
  fi

  if [[ "$churn_count" -ge 20 && "$build_fail_count" -ge 5 ]]; then
    vg_post_edit_append_warning "[CHURN CRITICAL] [review] [this-file] OBSERVATION: ${FILE_PATH##*/} has been edited ${churn_count} times and the project has ${build_fail_count} consecutive build failures — possible edit->fail->fix loop
FIX: Pause and classify: planned refactor vs failed repair loop. If planned, make one scoped finishing edit and verify; if failed loop, stop and re-check root cause (W-02)
DO NOT: Keep making equivalent fix attempts without fresh build output and a confirmed root cause"
    vg_log "post-edit-guard" "Edit" "escalate" "churn ${churn_count}x critical build_fails ${build_fail_count}x" "$FILE_PATH"
  elif [[ "$churn_count" -ge 20 ]]; then
    vg_post_edit_append_warning "[CHURN WARNING] [review] [this-file] OBSERVATION: ${FILE_PATH##*/} has been edited ${churn_count} times — high edit volume without repeated build-failure evidence
FIX: Pause and classify: planned refactor vs failed repair loop. If planned, make one scoped finishing edit and verify.
DO NOT: Treat edit count alone as proof of W-02 failure-loop behavior"
    vg_log "post-edit-guard" "Edit" "correction" "churn ${churn_count}x volume" "$FILE_PATH"
  elif [[ "$churn_count" -ge 10 ]]; then
    vg_post_edit_append_warning "[CHURN WARNING] [info] [this-file] OBSERVATION: ${FILE_PATH##*/} has been edited ${churn_count} times — high edit volume
FIX: Run full build to see the complete picture, or classify whether this is a planned refactor before continuing
DO NOT: Take any action — monitor and decide whether to continue"
    vg_log "post-edit-guard" "Edit" "correction" "churn ${churn_count}x warning" "$FILE_PATH"
  elif [[ "$churn_count" -ge 5 ]]; then
    vg_post_edit_append_warning "[CHURN] [info] [this-file] OBSERVATION: ${FILE_PATH##*/} has been edited ${churn_count} times
FIX: Check if you are in a correction loop before continuing
DO NOT: Take any action — this is informational only"
    vg_log "post-edit-guard" "Edit" "correction" "churn ${churn_count}x" "$FILE_PATH"
  fi
}

vg_post_edit_detect_w14_overlap() {
  local recent_conflict other_session other_agent other_hook other_tool
  recent_conflict=$(tail -500 "$VIBEGUARD_LOG_FILE" 2>/dev/null \
    | VG_FILE_PATH="$FILE_PATH" VG_SESSION="$VIBEGUARD_SESSION_ID" VG_AGENT="${VIBEGUARD_AGENT_TYPE:-}" VG_EVENT_LOG_LIB="$VG_EVENT_LOG_LIB" python3 -c '
import sys, os
sys.path.insert(0, os.environ["VG_EVENT_LOG_LIB"])
from event_log import iter_events_from_stream, parse_ts
from datetime import datetime, timezone
def normalize_path(path):
    path = (path or "").strip()
    if not path:
        return ""
    if not os.path.isabs(path):
        path = os.path.join(os.getcwd(), path)
    return os.path.normcase(os.path.realpath(path))

file_path = normalize_path(os.environ.get("VG_FILE_PATH", ""))
session = os.environ.get("VG_SESSION", "")
agent = os.environ.get("VG_AGENT", "")
now = datetime.now(timezone.utc)
conflicts = []
for e in iter_events_from_stream(sys.stdin.buffer):
    if e.get("tool") not in {"Edit", "Write"}:
        continue
    event_path = normalize_path(e.get("detail", "").split("||", 1)[0])
    if event_path != file_path:
        continue
    same_session = e.get("session") == session
    other_agent = e.get("agent", "") != agent
    if same_session and not other_agent:
        continue
    ts = parse_ts(e.get("ts"))
    if ts is None:
        continue
    if (now - ts).total_seconds() > 1800:
        continue
    conflicts.append((e.get("session", "?"), e.get("agent", "?"), e.get("hook", "?"), e.get("tool", "?")))
if conflicts:
    session_id, agent_name, hook_name, tool_name = conflicts[-1]
    print(f"{session_id}|{agent_name}|{hook_name}|{tool_name}")
' 2>/dev/null | tail -1 | tr -d '\r' || true)

  [[ -n "$recent_conflict" ]] || return 0
  IFS='|' read -r other_session other_agent other_hook other_tool <<< "$recent_conflict"
  vg_post_edit_append_warning "[W-14] [review] [this-file] OBSERVATION: another session or agent recently touched ${FILE_PATH##*/} (${other_tool} via ${other_hook}, session ${other_session}, agent ${other_agent:-unknown})
FIX: Confirm file ownership before continuing; prefer a dedicated worktree or single-owner merge path
DO NOT: Continue parallel/background edits to this file without explicit ownership"
  vg_log "post-edit-guard" "Edit" "warn" "w14 overlap recent session ${other_session} agent ${other_agent:-unknown}" "$FILE_PATH"
}

vg_post_edit_detect_w15_loop() {
  local past_consecutive total_consecutive
  past_consecutive=$(tail -200 "$VIBEGUARD_LOG_FILE" 2>/dev/null \
    | VG_FILE_PATH="$FILE_PATH" VG_SESSION="$VIBEGUARD_SESSION_ID" VG_EVENT_LOG_LIB="$VG_EVENT_LOG_LIB" python3 -c '
import sys, os
sys.path.insert(0, os.environ["VG_EVENT_LOG_LIB"])
from event_log import iter_events_from_stream

file_path = os.environ.get("VG_FILE_PATH", "")
session = os.environ.get("VG_SESSION", "")
edits = []
for e in iter_events_from_stream(sys.stdin.buffer):
    if (e.get("session") == session and e.get("tool") == "Edit"
            and e.get("hook") == "post-edit-guard"):
        edits.append(e.get("detail", "").split("||")[0].strip())
consec = 0
for ep in reversed(edits):
    if ep == file_path: consec += 1
    else: break
print(consec)
' 2>/dev/null | tr -d '[:space:]' || echo "0")
  past_consecutive="${past_consecutive:-0}"

  if [[ "$past_consecutive" -ge 2 ]]; then
    total_consecutive=$((past_consecutive + 1))
    vg_post_edit_append_warning "[W-15] [review] [this-file] OBSERVATION: ${total_consecutive} consecutive edits to ${FILE_PATH##*/} with no edits to other files in between (low-info loop suspect)
FIX: Pause — are these ${total_consecutive} edits solving the same problem? If change scope shrinks each round, report a blocker instead of continuing to round $((total_consecutive + 1))
DO NOT: Toggle between equivalent rewrites; do not continue same-direction micro-tuning without reporting"
    vg_log "post-edit-guard" "Edit" "warn" "w15 consecutive ${total_consecutive}x" "$FILE_PATH"
  fi
}

vg_post_edit_warn_count_for_file() {
  tail -500 "$VIBEGUARD_LOG_FILE" 2>/dev/null \
    | VG_FILE_PATH="$FILE_PATH" VG_SESSION="$VIBEGUARD_SESSION_ID" VG_EVENT_LOG_LIB="$VG_EVENT_LOG_LIB" python3 -c '
import sys, os
sys.path.insert(0, os.environ["VG_EVENT_LOG_LIB"])
from event_log import iter_events_from_stream

file_path = os.environ.get("VG_FILE_PATH", "")
session = os.environ.get("VG_SESSION", "")
count = 0
for e in iter_events_from_stream(sys.stdin.buffer):
    reason = e.get("reason", "") or ""
    churn_only = "[CHURN" in reason and "\n---\n" not in reason
    if churn_only:
        continue
    if e.get("session") == session and e.get("hook") == "post-edit-guard" and e.get("decision") == "warn" and e.get("detail", "").split("||")[0].strip() == file_path:
        count += 1
print(count)
' 2>/dev/null | tr -d '[:space:]' || echo "0"
}

#!/usr/bin/env bash
# Event-log-backed history detectors for post-edit-guard.sh.

_VG_POST_EDIT_HISTORY_LOADED=0
_VG_POST_EDIT_CHURN_COUNT=0
_VG_POST_EDIT_W15_COUNT=0
_VG_POST_EDIT_WARN_COUNT=0
_VG_POST_EDIT_W14=""

vg_post_edit_load_history() {
  [[ "$_VG_POST_EDIT_HISTORY_LOADED" -eq 0 ]] || return 0
  _VG_POST_EDIT_HISTORY_LOADED=1

  if [[ -z "${_VG_HELPER:-}" ]]; then
    return 0
  fi

  local history kind a b c d
  history=$(tail -500 "$VIBEGUARD_LOG_FILE" 2>/dev/null \
    | "$_VG_HELPER" post-edit-history "$VIBEGUARD_SESSION_ID" "$FILE_PATH" "${VIBEGUARD_AGENT_TYPE:-}" \
    2>/dev/null || true)

  while IFS=$'\t' read -r kind a b c d; do
    case "$kind" in
      CHURN) _VG_POST_EDIT_CHURN_COUNT="${a:-0}" ;;
      W15) _VG_POST_EDIT_W15_COUNT="${a:-0}" ;;
      WARN_COUNT) _VG_POST_EDIT_WARN_COUNT="${a:-0}" ;;
      W14) _VG_POST_EDIT_W14="${a:-?}|${b:-?}|${c:-?}|${d:-?}" ;;
    esac
  done <<< "$history"
}

vg_post_edit_detect_churn() {
  local churn_count
  vg_post_edit_load_history
  churn_count="${_VG_POST_EDIT_CHURN_COUNT:-0}"

  if [[ "$churn_count" -ge 20 ]]; then
    vg_post_edit_append_warning "[CHURN CRITICAL] [review] [this-file] OBSERVATION: ${FILE_PATH##*/} has been edited ${churn_count} times — possible edit→fail→fix loop
FIX: Stop current direction, review full build output, re-examine root cause (W-02)
DO NOT: Continue editing this file until root cause is confirmed"
    vg_log "post-edit-guard" "Edit" "escalate" "churn ${churn_count}x critical" "$FILE_PATH"
  elif [[ "$churn_count" -ge 10 ]]; then
    vg_post_edit_append_warning "[CHURN WARNING] [info] [this-file] OBSERVATION: ${FILE_PATH##*/} has been edited ${churn_count} times, possible correction loop
FIX: Run full build to see the complete picture, or use /vibeguard:learn to extract patterns
DO NOT: Take any action — monitor and decide whether to continue"
    vg_log "post-edit-guard" "Edit" "escalate" "churn ${churn_count}x warning" "$FILE_PATH"
  elif [[ "$churn_count" -ge 5 ]]; then
    vg_post_edit_append_warning "[CHURN] [info] [this-file] OBSERVATION: ${FILE_PATH##*/} has been edited ${churn_count} times
FIX: Check if you are in a correction loop before continuing
DO NOT: Take any action — this is informational only"
    vg_log "post-edit-guard" "Edit" "correction" "churn ${churn_count}x" "$FILE_PATH"
  fi
}

vg_post_edit_detect_w14_overlap() {
  local recent_conflict other_session other_agent other_hook other_tool
  vg_post_edit_load_history
  recent_conflict="${_VG_POST_EDIT_W14:-}"
  [[ -n "$recent_conflict" ]] || return 0

  IFS='|' read -r other_session other_agent other_hook other_tool <<< "$recent_conflict"
  vg_post_edit_append_warning "[W-14] [review] [this-file] OBSERVATION: another session or agent recently touched ${FILE_PATH##*/} (${other_tool} via ${other_hook}, session ${other_session}, agent ${other_agent:-unknown})
FIX: Confirm file ownership before continuing; prefer a dedicated worktree or single-owner merge path
DO NOT: Continue parallel/background edits to this file without explicit ownership"
  vg_log "post-edit-guard" "Edit" "warn" "w14 overlap recent session ${other_session} agent ${other_agent:-unknown}" "$FILE_PATH"
}

vg_post_edit_detect_w15_loop() {
  local past_consecutive total_consecutive
  vg_post_edit_load_history
  past_consecutive="${_VG_POST_EDIT_W15_COUNT:-0}"

  if [[ "$past_consecutive" -ge 2 ]]; then
    total_consecutive=$((past_consecutive + 1))
    vg_post_edit_append_warning "[W-15] [review] [this-file] OBSERVATION: ${total_consecutive} consecutive edits to ${FILE_PATH##*/} with no edits to other files in between (low-info loop suspect)
FIX: Pause — are these ${total_consecutive} edits solving the same problem? If change scope shrinks each round, report a blocker instead of continuing to round $((total_consecutive + 1))
DO NOT: Toggle between equivalent rewrites; do not continue same-direction micro-tuning without reporting"
    vg_log "post-edit-guard" "Edit" "warn" "w15 consecutive ${total_consecutive}x" "$FILE_PATH"
  fi
}

vg_post_edit_warn_count_for_file() {
  vg_post_edit_load_history
  printf '%s\n' "${_VG_POST_EDIT_WARN_COUNT:-0}"
}

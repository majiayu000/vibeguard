#!/usr/bin/env bash
# Event-log-backed history detectors for post-edit-guard.sh.

VG_EVENT_LOG_LIB="${VG_EVENT_LOG_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
VG_TIMEOUT_LIB="${VG_EVENT_LOG_LIB}/timeout.sh"
if [[ -f "${VG_TIMEOUT_LIB}" ]]; then
  # shellcheck source=hooks/_lib/timeout.sh
  source "${VG_TIMEOUT_LIB}"
fi

vg_post_edit_history_timeout_seconds() {
  local seconds="${VIBEGUARD_POST_EDIT_HISTORY_TIMEOUT:-2}"
  if [[ ! "${seconds}" =~ ^[1-9][0-9]*$ ]]; then
    seconds=2
  fi
  printf '%s\n' "${seconds}"
}

vg_post_edit_history_with_timeout() {
  local seconds
  seconds="$(vg_post_edit_history_timeout_seconds)"
  if declare -F vg_run_with_timeout >/dev/null 2>&1; then
    vg_run_with_timeout "${seconds}" "$@"
  else
    "$@"
  fi
}

vg_post_edit_history_query() {
  local tail_lines="$1" runtime_command="$2"
  shift 2

  vg_post_edit_history_with_timeout bash -c '
    set -o pipefail
    tail "-$1" "$2" 2>/dev/null | "$3" "$4" "${@:5}"
  ' vg-post-edit-history-query \
    "${tail_lines}" \
    "${VIBEGUARD_LOG_FILE}" \
    "${_VIBEGUARD_RUNTIME}" \
    "${runtime_command}" \
    "$@"
}

vg_post_edit_history_numeric_query() {
  local output
  output="$(vg_post_edit_history_query "$@" 2>/dev/null | tr -d '[:space:]')" || output=""
  if [[ "${output}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${output}"
  else
    printf '0\n'
  fi
}

vg_post_edit_count_build_failures() {
  local project_root
  # PERF-OK: build-failure history is repo-scoped; outside git uses an empty root.
  project_root=$(vg_post_edit_history_with_timeout git rev-parse --show-toplevel 2>/dev/null || echo "")
  vg_post_edit_history_numeric_query 200 build-fails "$VIBEGUARD_SESSION_ID" "$project_root"
}

vg_post_edit_detect_churn() {
  local churn_count build_fail_count
  churn_count="$(vg_post_edit_history_numeric_query 500 churn-count "$VIBEGUARD_SESSION_ID" "$FILE_PATH")"
  build_fail_count="0"

  if [[ "$churn_count" -ge 20 ]]; then
    build_fail_count="$(vg_post_edit_count_build_failures)"
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
  recent_conflict=$(vg_post_edit_history_query 500 post-edit-history "$VIBEGUARD_SESSION_ID" "$FILE_PATH" "${VIBEGUARD_AGENT_TYPE:-}" \
    2>/dev/null | awk -F '\t' '$1 == "W14" { print $2 "|" $3 "|" $4 "|" $5 }' | tail -1 | tr -d '\r' || true)

  [[ -n "$recent_conflict" ]] || return 0
  IFS='|' read -r other_session other_agent other_hook other_tool <<< "$recent_conflict"
  vg_post_edit_append_warning "[W-14] [review] [this-file] OBSERVATION: another session or agent recently touched ${FILE_PATH##*/} (${other_tool} via ${other_hook}, session ${other_session}, agent ${other_agent:-unknown})"'
FIX: Isolate via a dedicated worktree before continuing. Copy-paste:
  REPO=$(git rev-parse --show-toplevel) && SID=${VIBEGUARD_SESSION_ID:-$(date +%s)}
  BASE=${VIBEGUARD_WORKTREE_BASE:-${REPO}.wt}
  case "$BASE" in /*) ;; *) BASE="${REPO}/${BASE}" ;; esac
  BASE=${BASE%/}
  git worktree add "$BASE/$SID" -b "vg/$SID" HEAD
  cd "$BASE/$SID"
DO NOT: Continue parallel/background edits to this file without an isolated worktree'
  vg_log "post-edit-guard" "Edit" "warn" "w14 overlap recent session ${other_session} agent ${other_agent:-unknown}" "$FILE_PATH"
}

# W-15 low-information loop detector.
#
# Spec (rules/claude-rules/common/workflow.md, "Low-information loop detection"):
#   trigger when the change radius shrinks for three consecutive rounds.
#
# Implementation:
#   1. Walk the session's post-edit-guard Edit history backwards.
#   2. Collect the consecutive trail of edits whose file_path equals the current
#      one. Stop on the first edit to a different file.
#   3. Recover each prior edit's size_delta from the detail field (encoded as
#      "<file_path>||delta=<N>" by post-edit-guard.sh).
#   4. Combined with the current edit's delta, fire only when:
#      - past_consecutive >= 2 (i.e. 3+ same-file edits in a row, including
#        the current one),
#      - |Δ| is non-increasing across the 3 most recent rounds (radius
#        actually shrinks per spec — not merely "same file"), and
#      - |latest_Δ| < 300 chars (caps to micro-tuning; large content adds
#        such as long markdown sections never qualify as low-yield).
#
# Downgrade path (U-32 compliance): set VIBEGUARD_SUPPRESS_W15=1 to skip the
# detector entirely. Use this when writing long-form markdown / RFC docs where
# every edit naturally adds a new section.
vg_post_edit_detect_w15_loop() {
  [[ "${VIBEGUARD_SUPPRESS_W15:-0}" == "1" ]] && return 0

  # Known FP class: documentation / notes / changelog edits naturally
  # produce a sequence of small same-file appends (e.g. daily TODO lists)
  # that the spec already calls out as a known weakness. Skip these paths.
  # Override the skip by unsetting VIBEGUARD_W15_SKIP_DOCS=0.
  if [[ "${VIBEGUARD_W15_SKIP_DOCS:-1}" == "1" ]]; then
    case "$FILE_PATH" in
      *.md|*.markdown|*.rst|*.txt|*.adoc) return 0 ;;
      notes/*|*/notes/*|docs/daily/*|*/docs/daily/*) return 0 ;;
      CHANGELOG*|*/CHANGELOG*|TODO*|*/TODO*|HISTORY*|*/HISTORY*) return 0 ;;
    esac
  fi

  local current_delta past_consecutive past_deltas raw
  current_delta="${VG_W15_CURRENT_DELTA:-0}"

  raw=$(vg_post_edit_history_query 200 post-edit-w15 "$VIBEGUARD_SESSION_ID" "$FILE_PATH" \
    2>/dev/null || printf "0\n\n")

  past_consecutive=$(printf '%s\n' "$raw" | sed -n '1p' | tr -d '[:space:]')
  past_deltas=$(printf '%s\n' "$raw" | sed -n '2p')
  past_consecutive="${past_consecutive:-0}"

  [[ "$past_consecutive" -ge 2 ]] || return 0

  local prev_delta prev2_delta cur_abs prev_abs prev2_abs total_consecutive
  IFS=',' read -r prev_delta prev2_delta <<< "$past_deltas"

  # Need both prior deltas to evaluate radius shrinkage; legacy log entries
  # without delta metadata cannot be compared and are ignored (fail-closed).
  if [[ -z "${prev_delta:-}" || -z "${prev2_delta:-}" ]]; then
    return 0
  fi

  cur_abs="${current_delta#-}"
  prev_abs="${prev_delta#-}"
  prev2_abs="${prev2_delta#-}"

  # Spec: change radius shrinks across the 3 most recent rounds and the latest
  # round is in the micro-tuning band (<300 chars). Otherwise it is just a
  # natural sequence of same-file edits (e.g. writing a long doc).
  if [[ "$prev2_abs" -ge "$prev_abs" ]] \
     && [[ "$prev_abs" -ge "$cur_abs" ]] \
     && [[ "$cur_abs" -lt 300 ]]; then
    total_consecutive=$((past_consecutive + 1))
    vg_post_edit_append_warning "[W-15] [review] [this-file] OBSERVATION: ${total_consecutive} consecutive edits to ${FILE_PATH##*/} with shrinking change radius (|Δ| ${prev2_abs}→${prev_abs}→${cur_abs} chars; latest <300)
FIX: Pause — are these ${total_consecutive} edits solving the same problem? If radius keeps shrinking, report a blocker instead of continuing to round $((total_consecutive + 1))
DO NOT: Toggle between equivalent rewrites; do not continue same-direction micro-tuning without reporting
ESCAPE: set VIBEGUARD_SUPPRESS_W15=1 to suppress (e.g. for long-document writing)"
    vg_log "post-edit-guard" "Edit" "warn" "w15 shrinking radius ${prev2_abs}>${prev_abs}>${cur_abs}" "$EDIT_DETAIL"
  fi
}

vg_post_edit_warn_count_for_file() {
  vg_post_edit_history_numeric_query 500 warn-count "$VIBEGUARD_SESSION_ID" "$FILE_PATH"
}

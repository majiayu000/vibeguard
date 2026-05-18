#!/usr/bin/env bash
# VibeGuard PostToolUse(Edit) Hook
#
# After editing the source code, check whether quality problems have been introduced:
# - Rust: Add unwrap()/expect() to non-test code
# - Rust: Added let _ = silently discard Result
# - General: Added hardcoded paths (.db/.sqlite)
#
# Output warning context, do not prevent operations (post-event reminder)
#
# Suppress single-line warnings: add the following line before the detected line:
#   // vibeguard-disable-next-line RS-03 -- reason   (Rust/TS/JS/Go)
#   # vibeguard-disable-next-line RS-03 -- reason    (Python/Shell)

set -euo pipefail

source "$(dirname "$0")/log.sh"

INPUT=$(cat)

if [[ -n "${_VIBEGUARD_RUNTIME:-}" ]]; then
  _VG_U16_BASE_LIMIT=$(vg_config_get_int VG_U16_LIMIT u16.limit 800)
  _VG_FAST_RESULT=$(printf '%s' "$INPUT" \
    | "$_VIBEGUARD_RUNTIME" post-edit-fast-check "$_VG_U16_BASE_LIMIT" "$VIBEGUARD_SESSION_ID" "${VIBEGUARD_AGENT_TYPE:-}" "$VIBEGUARD_LOG_FILE" \
    2>/dev/null || true)
  _VG_FAST_STATUS="${_VG_FAST_RESULT%%$'\n'*}"
  case "$_VG_FAST_STATUS" in
    SKIP)
      exit 0
      ;;
    FAST_LOGGED)
      exit 0
      ;;
    FAST_OUTPUT)
      _VG_FAST_PAYLOAD="${_VG_FAST_RESULT#*$'\n'}"
      [[ "$_VG_FAST_PAYLOAD" != "$_VG_FAST_RESULT" ]] && printf '%s\n' "$_VG_FAST_PAYLOAD"
      exit 0
      ;;
    FAST_PASS)
      FILE_PATH="${_VG_FAST_RESULT#*$'\n'}"
      [[ "$FILE_PATH" == "$_VG_FAST_RESULT" ]] && FILE_PATH=""
      vg_log "post-edit-guard" "Edit" "pass" "" "$FILE_PATH"
      exit 0
      ;;
  esac
fi

vg_start_timer
source "$(dirname "$0")/_lib/post_edit_common.sh"
source "$(dirname "$0")/_lib/stub_detect.sh"
source "$(dirname "$0")/_lib/post_edit_quality.sh"
source "$(dirname "$0")/_lib/post_edit_history.sh"

RESULT=$(printf '%s' "$INPUT" | vg_json_two_fields "tool_input.file_path" "tool_input.new_string")

FILE_PATH=$(echo "$RESULT" | head -1)
NEW_STRING=$(echo "$RESULT" | tail -n +2)

if [[ -z "$FILE_PATH" ]] || [[ -z "$NEW_STRING" ]]; then
  exit 0
fi

# Compute size_delta = len(new_string) - len(old_string).
# Used by W-15 to detect shrinking change radius (per spec).
OLD_STRING=$(echo "$INPUT" | vg_json_field "tool_input.old_string")
SIZE_DELTA=$(( ${#NEW_STRING} - ${#OLD_STRING} ))

# Encode size_delta in the event-log detail field so future W-15 invocations can
# read it. Existing parsers (W-14, churn, warn-count) split detail on "||" and
# only consume the first segment, so appending metadata is backward-compatible.
EDIT_DETAIL="${FILE_PATH}||delta=${SIZE_DELTA}"
export VG_W15_CURRENT_DELTA="$SIZE_DELTA"

WARNINGS=""

_VG_FAST_STATELESS=0
case "$FILE_PATH" in
  *.rs)
    _VG_FAST_STATELESS=1
    [[ "$NEW_STRING" == *".unwrap("* || "$NEW_STRING" == *".expect("* ]] && _VG_FAST_STATELESS=0
    [[ "$NEW_STRING" =~ (^|[[:space:]])let[[:space:]]+_[[:space:]]*= ]] && _VG_FAST_STATELESS=0
    [[ "$NEW_STRING" == *".db\""* || "$NEW_STRING" == *".sqlite\""* ]] && _VG_FAST_STATELESS=0
    [[ "$NEW_STRING" == *"todo!("* || "$NEW_STRING" == *"unimplemented!("* || "$NEW_STRING" == *'panic!("not implemented'* ]] && _VG_FAST_STATELESS=0
    if [[ "$_VG_FAST_STATELESS" -eq 1 ]]; then
      _VG_WITHOUT_NEWLINES="${NEW_STRING//$'\n'/}"
      _VG_DIFF_LINES=$(( ${#NEW_STRING} - ${#_VG_WITHOUT_NEWLINES} + 1 ))
      [[ "$_VG_DIFF_LINES" -gt 200 ]] && _VG_FAST_STATELESS=0
    fi
    if [[ "$_VG_FAST_STATELESS" -eq 1 && -f "$FILE_PATH" ]]; then
      _VG_U16_BASE_LIMIT=$(vg_config_get_int VG_U16_LIMIT u16.limit 800)
      _VG_FILE_LINES=$(wc -l < "$FILE_PATH" | tr -d ' ')
      [[ "${_VG_FILE_LINES:-0}" -gt "$_VG_U16_BASE_LIMIT" ]] && _VG_FAST_STATELESS=0
    fi
    ;;
esac

if [[ "$_VG_FAST_STATELESS" -ne 1 ]]; then
  vg_post_edit_detect_rust
  vg_post_edit_detect_ts_console
  vg_post_edit_detect_python_print
  vg_post_edit_detect_hardcoded_db_path
  vg_post_edit_detect_go
  vg_post_edit_detect_stubs
  vg_post_edit_detect_large_edit
  vg_post_edit_detect_u16_size
fi
vg_post_edit_detect_churn
vg_post_edit_detect_w14_overlap
vg_post_edit_detect_w15_loop

if [[ -z "$WARNINGS" ]]; then
  vg_log "post-edit-guard" "Edit" "pass" "" "$EDIT_DETAIL"
  exit 0
fi

# --- Escalation detection ---
# The same file is warned more than 3 times in the current log → upgrade to escalate
DECISION="warn"
WARN_COUNT_FOR_FILE=$(vg_post_edit_warn_count_for_file)
WARN_COUNT_FOR_FILE="${WARN_COUNT_FOR_FILE:-0}"

if [[ "$WARN_COUNT_FOR_FILE" -ge 3 ]]; then
  DECISION="escalate"
  WARNINGS="[ESCALATE] [review] [this-file] OBSERVATION: this file has triggered ${WARN_COUNT_FOR_FILE} warnings — user intervention recommended
FIX: Stop and review the warnings below before continuing
DO NOT: Continue editing this file without reviewing all warnings
---
${WARNINGS}"
fi

vg_log "post-edit-guard" "Edit" "$DECISION" "$WARNINGS" "$EDIT_DETAIL"

# Output warnings without spawning Python.
_VG_PREFIX="VIBEGUARD quality warning"
[[ "$DECISION" == "escalate" ]] && _VG_PREFIX="VIBEGUARD upgrade warning"
_VG_CONTEXT="${_VG_PREFIX}：${WARNINGS}"
_VG_CONTEXT="${_VG_CONTEXT//\\/\\\\}"
_VG_CONTEXT="${_VG_CONTEXT//\"/\\\"}"
_VG_CONTEXT="${_VG_CONTEXT//$'\n'/\\n}"
_VG_CONTEXT="${_VG_CONTEXT//$'\t'/\\t}"
printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$_VG_CONTEXT"

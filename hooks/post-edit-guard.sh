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
source "$(dirname "$0")/_lib/post_edit_common.sh"
source "$(dirname "$0")/_lib/stub_detect.sh"
source "$(dirname "$0")/_lib/post_edit_quality.sh"
source "$(dirname "$0")/_lib/post_edit_history.sh"
vg_start_timer
VG_EVENT_LOG_LIB="${VG_EVENT_LOG_LIB:-$(cd "$(dirname "$0")/_lib" && pwd)}"

INPUT=$(cat)

RESULT=$(echo "$INPUT" | vg_json_two_fields "tool_input.file_path" "tool_input.new_string")

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

vg_post_edit_detect_rust
vg_post_edit_detect_ts_console
vg_post_edit_detect_python_print
vg_post_edit_detect_hardcoded_db_path
vg_post_edit_detect_go
vg_post_edit_detect_stubs
vg_post_edit_detect_large_edit
vg_post_edit_detect_u16_size
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

# Output warnings (pass parameters through environment variables to avoid injection)
VG_WARNINGS="$WARNINGS" VG_DECISION="$DECISION" python3 -c '
import json, os
warnings = os.environ.get("VG_WARNINGS", "")
decision = os.environ.get("VG_DECISION", "warn")
prefix = "VIBEGUARD upgrade warning" if decision == "escalate" else "VIBEGUARD quality warning"
result = {
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": prefix + "：" + warnings
    }
}
print(json.dumps(result, ensure_ascii=False))
'

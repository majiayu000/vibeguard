#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
hook_test_init

header "post-edit-guard.sh — CHURN critical evidence gate"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR" "$VIBEGUARD_LOG_DIR"' EXIT

export VIBEGUARD_SESSION_ID="churn-test-session"
export VG_EVENT_LOG_LIB="${REPO_DIR}/hooks/_lib"
source hooks/log.sh
source hooks/_lib/post_edit_common.sh
source hooks/_lib/post_edit_history.sh

# Force the shell/Python path so this test validates the hook contract even when
# a stale installed vg-helper exists in ~/.vibeguard.
_VG_HELPER=""

FILE_PATH="$WORK_DIR/planned_refactor.tsx"
touch "$FILE_PATH"

append_event() {
  local hook="$1" tool="$2" decision="$3" reason="$4" detail="$5"
  printf '{"ts":"%s","session":"%s","hook":"%s","tool":"%s","decision":"%s","reason":"%s","detail":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$VIBEGUARD_SESSION_ID" "$hook" "$tool" "$decision" "$reason" "$detail" >> "$VIBEGUARD_LOG_FILE"
}

seed_edits() {
  local count="$1"
  : > "$VIBEGUARD_LOG_FILE"
  for _ in $(seq 1 "$count"); do
    append_event "post-edit-guard" "Edit" "pass" "" "$FILE_PATH"
  done
}

seed_build_failures() {
  local count="$1"
  for i in $(seq 1 "$count"); do
    append_event "post-build-check" "Edit" "warn" "Build errors 1" "${REPO_DIR}/src/failing_${i}.tsx"
  done
}

seed_edits 20
WARNINGS=""
vg_post_edit_detect_churn
assert_contains "$WARNINGS" "[CHURN WARNING]" "20 same-file edits without build failures stay at warning level"
assert_not_contains "$WARNINGS" "[CHURN CRITICAL]" "count-only churn does not emit critical"
assert_not_contains "$WARNINGS" "edit->fail->fix loop" "count-only churn does not claim failed repair loop"
assert_not_contains "$WARNINGS" "Continue editing this file until root cause" "count-only churn does not hard-stop planned refactors"

seed_edits 20
seed_build_failures 5
WARNINGS=""
vg_post_edit_detect_churn
assert_contains "$WARNINGS" "[CHURN CRITICAL]" "churn plus repeated build failures emits critical"
assert_contains "$WARNINGS" "5 consecutive build failures" "critical churn cites corroborating build evidence"
assert_contains "$WARNINGS" "Pause and classify" "critical churn asks for classification before stopping"
assert_not_contains "$WARNINGS" "Continue editing this file until root cause" "critical churn avoids old hard-stop wording"

: > "$VIBEGUARD_LOG_FILE"
for _ in $(seq 1 3); do
  append_event "post-edit-guard" "Edit" "warn" "[CHURN WARNING] edit volume only" "$FILE_PATH"
done
warn_count="$(vg_post_edit_warn_count_for_file)"
assert_exit_zero "pure churn warnings do not count toward warn escalation" test "$warn_count" = "0"

append_event "post-edit-guard" "Edit" "warn" "[RS-03] unwrap introduced" "$FILE_PATH"
warn_count="$(vg_post_edit_warn_count_for_file)"
assert_exit_zero "non-churn warning still counts toward warn escalation" test "$warn_count" = "1"

hook_test_finish

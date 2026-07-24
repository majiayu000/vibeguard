#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
hook_test_init

header "post-edit-guard.sh — CHURN critical evidence gate"

# Repo-local work dir: TMPDIR paths are churn-exempt session temp (issue #681).
WORK_DIR=$(mktemp -d "$REPO_DIR/.tmp-churn.XXXXXX")
trap 'rm -rf "$WORK_DIR" "$VIBEGUARD_LOG_DIR"' EXIT

export VIBEGUARD_SESSION_ID="churn-test-session"
export VG_EVENT_LOG_LIB="${REPO_DIR}/hooks/_lib"
source hooks/log.sh
source hooks/_lib/post_edit_common.sh
source hooks/_lib/post_edit_history.sh

FILE_PATH="$WORK_DIR/planned_refactor.tsx"
touch "$FILE_PATH"

append_event() {
  local hook="$1" tool="$2" decision="$3" reason="$4" detail="$5"
  vg_post_edit_history_reset
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

assert_exit_zero "post-edit history default timeout stays below aggregate hook budget" test "$(vg_post_edit_history_timeout_seconds)" = "2"
VIBEGUARD_POST_EDIT_HISTORY_TIMEOUT=bad
assert_exit_zero "invalid post-edit history timeout falls back below aggregate hook budget" test "$(vg_post_edit_history_timeout_seconds)" = "2"
unset VIBEGUARD_POST_EDIT_HISTORY_TIMEOUT

summary_runtime="$WORK_DIR/summary-runtime.sh"
summary_calls="$WORK_DIR/summary-runtime-calls.log"
cat > "$summary_runtime" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "${1:-}" >> "$VG_STUB_RUNTIME_CALLS"
cat >/dev/null || true

case "${1:-}" in
  post-edit-history)
    printf 'CHURN\t20\n'
    printf 'W15\t2\n'
    printf 'W15_DELTAS\t100,200\n'
    printf 'WARN_COUNT\t1\n'
    printf 'BUILD_FAILS\t5\n'
    ;;
  warn-count)
    printf '3\n'
    ;;
  *)
    printf '0\n'
    ;;
esac
STUB
chmod +x "$summary_runtime"

old_runtime="$_VIBEGUARD_RUNTIME"
_VIBEGUARD_RUNTIME="$summary_runtime"
export VG_STUB_RUNTIME_CALLS="$summary_calls"
VG_W15_CURRENT_DELTA=50
EDIT_DETAIL="$FILE_PATH||delta=50"
vg_post_edit_history_reset
WARNINGS=""
vg_post_edit_detect_churn
cached_warn_count="$(vg_post_edit_warn_count_for_file)"
fresh_warn_count="$(vg_post_edit_warn_count_for_file --fresh)"
vg_post_edit_detect_w15_loop
assert_contains "$WARNINGS" "[CHURN CRITICAL]" "combined post-edit history keeps churn critical semantics"
assert_contains "$WARNINGS" "[W-15]" "combined post-edit history keeps W-15 semantics"
assert_exit_zero "combined post-edit history keeps cached warn-count semantics" test "$cached_warn_count" = "1"
assert_exit_zero "final escalation path refreshes warn-count semantics" test "$fresh_warn_count" = "3"
assert_exit_zero "post-edit history summary uses one history query across detectors" \
  test "$(grep -c '^post-edit-history$' "$summary_calls" | tr -d '[:space:]')" = "1"
assert_exit_zero "fresh warn-count uses one bounded refresh query" \
  test "$(grep -c '^warn-count$' "$summary_calls" | tr -d '[:space:]')" = "1"
assert_contains "$(cat "$summary_calls")" "post-edit-history" "combined summary calls post-edit-history"
assert_not_contains "$(cat "$summary_calls")" "churn-count" "combined summary avoids legacy churn-count call"
assert_not_contains "$(cat "$summary_calls")" "build-fails" "combined summary avoids legacy build-fails call"
_VIBEGUARD_RUNTIME="$old_runtime"
unset VG_STUB_RUNTIME_CALLS
unset VG_W15_CURRENT_DELTA
unset EDIT_DETAIL

slow_runtime="$WORK_DIR/slow-runtime.sh"
cat > "$slow_runtime" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  churn-count|warn-count|build-fails|post-edit-history|post-edit-w15)
    cat >/dev/null || true
    sleep 5
    printf '99\n'
    ;;
  *)
    cat >/dev/null || true
    ;;
esac
STUB
chmod +x "$slow_runtime"

_VIBEGUARD_RUNTIME="$slow_runtime"
export VIBEGUARD_POST_EDIT_HISTORY_TIMEOUT=1
seed_edits 20
WARNINGS=""
timeout_started="$(date +%s)"
vg_post_edit_detect_churn
timeout_elapsed=$(( $(date +%s) - timeout_started ))
assert_exit_zero "post-edit history runtime timeout returns promptly" test "$timeout_elapsed" -lt 3
assert_not_contains "$WARNINGS" "[CHURN" "timed-out churn query degrades to zero warnings"
_VIBEGUARD_RUNTIME="$old_runtime"
unset VIBEGUARD_POST_EDIT_HISTORY_TIMEOUT

hook_test_finish

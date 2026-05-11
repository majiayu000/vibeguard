#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
hook_test_init

header "post-edit-guard.sh — W-15 spec compliance (size delta semantics)"
# =========================================================

_w15_dir=$(mktemp -d "$REPO_DIR/.tmp-w15.XXXXXX")
trap 'rm -rf "$_w15_dir"' EXIT
_w15_project_hash=$(printf '%s' "$REPO_DIR" | shasum -a 256 2>/dev/null | cut -c1-8)
_w15_log_dir="$VIBEGUARD_LOG_DIR/projects/${_w15_project_hash}"
_w15_log_file="$_w15_log_dir/events.jsonl"
mkdir -p "$_w15_log_dir"

# Helper: seed two prior post-edit-guard Edit events for a session/file with
# specified deltas, simulating consecutive same-file edits.
seed_w15_history() {
  local session="$1" file_path="$2" delta1="$3" delta2="$4"
  : > "$_w15_log_file"
  printf '{"ts":"%s","session":"%s","hook":"post-edit-guard","tool":"Edit","decision":"pass","detail":"%s||delta=%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$session" "$file_path" "$delta1" >> "$_w15_log_file"
  printf '{"ts":"%s","session":"%s","hook":"post-edit-guard","tool":"Edit","decision":"pass","detail":"%s||delta=%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$session" "$file_path" "$delta2" >> "$_w15_log_file"
}

# ---------------------------------------------------------------------------
# Case 1: shrinking radius below the micro-tuning cap → W-15 fires.
# Sequence: |Δ| 200 → 100 → 50 (all <300; non-increasing).
# ---------------------------------------------------------------------------
_w15_target="$_w15_dir/loop.py"
printf 'x = 1\n' > "$_w15_target"
seed_w15_history "w15-shrink-session" "$_w15_target" 200 100

# Current edit: new_string len 60, old_string len 10 → delta=+50 (|Δ|=50 < 300)
# Use a non-trigger language file (no quality warnings) so the W-15 line is
# the only warning in the output.
result_shrink=$(printf '{"tool_input":{"file_path":"%s","old_string":"%s","new_string":"%s"}}' \
  "$_w15_target" \
  "$(printf 'a%.0s' {1..10})" \
  "$(printf 'b%.0s' {1..60})" \
  | VIBEGUARD_LOG_DIR="$VIBEGUARD_LOG_DIR" VIBEGUARD_SESSION_ID="w15-shrink-session" bash hooks/post-edit-guard.sh)
assert_contains "$result_shrink" "[W-15]" "W-15 fires when change radius shrinks below micro-tuning cap"
assert_contains "$result_shrink" "200" "W-15 message reports the oldest |Δ|"

# ---------------------------------------------------------------------------
# Case 2: same file, growing markdown content → W-15 does NOT fire.
# Each edit adds ~500 chars of new content; |Δ| grows or stays large, so the
# spec's "shrinking radius" precondition is not met.
# ---------------------------------------------------------------------------
_w15_md="$_w15_dir/spec.md"
printf '# spec\n' > "$_w15_md"
seed_w15_history "w15-md-session" "$_w15_md" 400 500

result_md=$(printf '{"tool_input":{"file_path":"%s","old_string":"","new_string":"%s"}}' \
  "$_w15_md" \
  "$(printf '# section\n%.0s' {1..120})" \
  | VIBEGUARD_LOG_DIR="$VIBEGUARD_LOG_DIR" VIBEGUARD_SESSION_ID="w15-md-session" bash hooks/post-edit-guard.sh)
assert_not_contains "$result_md" "[W-15]" "W-15 does not fire when markdown sections keep growing"

# ---------------------------------------------------------------------------
# Case 3: VIBEGUARD_SUPPRESS_W15=1 honors the downgrade path even when the
# shrinking-radius preconditions hold.
# ---------------------------------------------------------------------------
seed_w15_history "w15-suppress-session" "$_w15_target" 200 100
result_suppress=$(printf '{"tool_input":{"file_path":"%s","old_string":"%s","new_string":"%s"}}' \
  "$_w15_target" \
  "$(printf 'a%.0s' {1..10})" \
  "$(printf 'b%.0s' {1..60})" \
  | VIBEGUARD_LOG_DIR="$VIBEGUARD_LOG_DIR" VIBEGUARD_SESSION_ID="w15-suppress-session" \
    VIBEGUARD_SUPPRESS_W15=1 bash hooks/post-edit-guard.sh)
assert_not_contains "$result_suppress" "[W-15]" "VIBEGUARD_SUPPRESS_W15=1 disables the detector"

# ---------------------------------------------------------------------------
# Case 4: same file, large latest delta (>=300) → W-15 does NOT fire.
# Sequence |Δ| 600 → 400 → 350. Non-increasing, but latest 350 is above the
# micro-tuning cap.
# ---------------------------------------------------------------------------
seed_w15_history "w15-largeadd-session" "$_w15_target" 600 400
result_large=$(printf '{"tool_input":{"file_path":"%s","old_string":"","new_string":"%s"}}' \
  "$_w15_target" \
  "$(printf 'c%.0s' {1..350})" \
  | VIBEGUARD_LOG_DIR="$VIBEGUARD_LOG_DIR" VIBEGUARD_SESSION_ID="w15-largeadd-session" bash hooks/post-edit-guard.sh)
assert_not_contains "$result_large" "[W-15]" "W-15 ignores large content additions even with non-increasing radius"

# ---------------------------------------------------------------------------
# Case 5: legacy log entries without delta metadata → fail-closed (no fire).
# ---------------------------------------------------------------------------
: > "$_w15_log_file"
printf '{"ts":"%s","session":"w15-legacy","hook":"post-edit-guard","tool":"Edit","decision":"pass","detail":"%s"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_w15_target" >> "$_w15_log_file"
printf '{"ts":"%s","session":"w15-legacy","hook":"post-edit-guard","tool":"Edit","decision":"pass","detail":"%s"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_w15_target" >> "$_w15_log_file"

result_legacy=$(printf '{"tool_input":{"file_path":"%s","old_string":"%s","new_string":"%s"}}' \
  "$_w15_target" \
  "$(printf 'a%.0s' {1..10})" \
  "$(printf 'b%.0s' {1..60})" \
  | VIBEGUARD_LOG_DIR="$VIBEGUARD_LOG_DIR" VIBEGUARD_SESSION_ID="w15-legacy" bash hooks/post-edit-guard.sh)
assert_not_contains "$result_legacy" "[W-15]" "Legacy log entries without delta metadata fail closed"

# ---------------------------------------------------------------------------
# Case 6: W-14 overlap warning in the same hook run has no delta metadata and
# must not mask the shrinking-radius W-15 trail.
# ---------------------------------------------------------------------------
seed_w15_history "w15-w14-mask" "$_w15_target" 200 100
printf '{"ts":"%s","session":"w15-w14-mask","hook":"post-edit-guard","tool":"Edit","decision":"warn","reason":"w14 overlap recent session other agent unknown","detail":"%s"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_w15_target" >> "$_w15_log_file"

result_w14_mask=$(printf '{"tool_input":{"file_path":"%s","old_string":"%s","new_string":"%s"}}' \
  "$_w15_target" \
  "$(printf 'a%.0s' {1..10})" \
  "$(printf 'b%.0s' {1..60})" \
  | VIBEGUARD_LOG_DIR="$VIBEGUARD_LOG_DIR" VIBEGUARD_SESSION_ID="w15-w14-mask" bash hooks/post-edit-guard.sh)
assert_contains "$result_w14_mask" "[W-15]" "W-14 no-delta warning does not mask W-15 shrinking-radius detection"

# =========================================================
hook_test_finish

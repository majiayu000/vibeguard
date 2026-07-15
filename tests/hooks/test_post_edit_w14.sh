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
  printf '{"tool_input":{"file_path":"%s","new_string":"value = 3\\n"}}' "$_w14_rel" \
    | VIBEGUARD_LOG_DIR="$VIBEGUARD_LOG_DIR" VIBEGUARD_CLI="codex" VIBEGUARD_SESSION_ID="current-session" bash hooks/post-edit-guard.sh
)
assert_not_contains "$_w14_repeat" "[W-14]" "W-14 suppresses the same directed pair and file inside cooldown"
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
rm -rf "$_w14_dir"

hook_test_finish

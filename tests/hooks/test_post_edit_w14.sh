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
rm -rf "$_w14_dir"
assert_contains "$_w14_result" "[W-14]" "W-14 detects relative/absolute matches for the same file"

hook_test_finish

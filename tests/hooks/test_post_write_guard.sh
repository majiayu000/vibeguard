#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
hook_test_init

header "post-write-guard.sh — duplicate detection"
# =========================================================

# Non-source files (.md) should be allowed
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_test_readme.md","content":"# test"}}' | bash hooks/post-write-guard.sh)
assert_not_contains "$result" "VIBEGUARD" "Non-source files (.md) are allowed"

# Release when there is no git project (use a path that does not exist under /tmp)
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_no_git_project/src/main.rs","content":"fn main() {}"}}' | bash hooks/post-write-guard.sh)
assert_not_contains "$result" "VIBEGUARD" "Release if there is no git project"

# Empty content is released
result=$(echo '{"tool_input":{"file_path":"src/lib.rs","content":""}}' | bash hooks/post-write-guard.sh)
assert_not_contains "$result" "VIBEGUARD" "Empty content is released"

# Empty file_path is allowed
result=$(echo '{"tool_input":{"file_path":"","content":"fn main() {}"}}' | bash hooks/post-write-guard.sh)
assert_not_contains "$result" "VIBEGUARD" "Empty file_path is allowed"

# Git worktrees expose .git as a file, and hook inputs can be relative paths.
tmp_repo_worktree="$(mktemp -d)"
mkdir -p "$tmp_repo_worktree/src"
printf 'gitdir: /tmp/nonexistent\n' >"$tmp_repo_worktree/.git"
json_payload='{"tool_input":{"file_path":"src/new_file.rs","content":"fn createdThing() {}"}}'
if ! result=$(cd "$tmp_repo_worktree" && printf '%s\n' "$json_payload" | perl -e 'alarm 3; exec @ARGV' bash "$REPO_DIR/hooks/post-write-guard.sh"); then
  result="TIMEOUT"
fi
assert_not_contains "$result" "TIMEOUT" "Worktree .git file + relative source path does not hang"
assert_not_contains "$result" "No git project" "Worktree .git file + relative source path resolves project root"
rm -rf "$tmp_repo_worktree"

# Source code files with the same name should alert
tmp_repo_same_name="$(mktemp -d)"
git -C "$tmp_repo_same_name" init -q
mkdir -p "$tmp_repo_same_name/src/existing" "$tmp_repo_same_name/src/new"
cat >"$tmp_repo_same_name/src/existing/service.py" <<'EOF'
def existing_service():
    return True
EOF
json_payload=$(printf '{"tool_input":{"file_path":"%s","content":"def create_service():\\n    return True"}}' "$tmp_repo_same_name/src/new/service.py")
result=$(echo "$json_payload" | bash hooks/post-write-guard.sh)
assert_contains "$result" "[L1]" "Detect duplicate source files with the same name"
rm -rf "$tmp_repo_same_name"

# Duplicate definitions should alert
tmp_repo_dup_def="$(mktemp -d)"
git -C "$tmp_repo_dup_def" init -q
mkdir -p "$tmp_repo_dup_def/src/existing" "$tmp_repo_dup_def/src/new"
cat >"$tmp_repo_dup_def/src/existing/handler.py" <<'EOF'
def processOrder():
    return 1
EOF
json_payload=$(printf '{"tool_input":{"file_path":"%s","content":"def processOrder():\\n    return 2"}}' "$tmp_repo_dup_def/src/new/new_handler.py")
result=$(echo "$json_payload" | bash hooks/post-write-guard.sh)
assert_contains "$result" "[L1]" "Detect duplicate definitions"
rm -rf "$tmp_repo_dup_def"

# Prompt for downgrade when scanning budget is exceeded
tmp_repo_budget="$(mktemp -d)"
git -C "$tmp_repo_budget" init -q
mkdir -p "$tmp_repo_budget/src"
cat >"$tmp_repo_budget/src/existing.py" <<'EOF'
def keepExisting():
    return "ok"
EOF
json_payload=$(printf '{"tool_input":{"file_path":"%s","content":"def keepExisting():\\n    return \\"new\\""}}' "$tmp_repo_budget/src/new_file.py")
result=$(echo "$json_payload" | VG_SCAN_MAX_FILES=0 bash hooks/post-write-guard.sh)
assert_contains "$result" "[L1]" "Downgrade when file budget exceeded"
rm -rf "$tmp_repo_budget"

# When the new source code file has a file with the same name, you should warn (use the existing log.sh in the current warehouse)
result=$(echo '{"tool_input":{"file_path":"'${REPO_DIR}'/hooks/subdir/log.sh","content":"#!/bin/bash\necho test"}}' | bash hooks/post-write-guard.sh)
# log.sh already exists in the hooks/ directory, if detected there should be VIBEGUARD output
# But .sh is not in VG_SOURCE_EXTS, so it is allowed
assert_not_contains "$result" "VIBEGUARD" "Non-source extension (.sh) allowed"

# Go: same basename across different packages is the standard convention
# (e.g. internal/foo/config.go vs internal/cli/config.go) and must not warn.
tmp_repo_go="$(mktemp -d)"
git -C "$tmp_repo_go" init -q
mkdir -p "$tmp_repo_go/internal/foo" "$tmp_repo_go/internal/cli"
cat >"$tmp_repo_go/internal/foo/config.go" <<'EOF'
package foo

type FooConfig struct{}
EOF
cat >"$tmp_repo_go/internal/cli/config.go" <<'EOF'
package cli

type CLIConfig struct{}
EOF
json_payload=$(printf '{"tool_input":{"file_path":"%s","content":"package cli\\n\\ntype CLIConfig struct{}"}}' "$tmp_repo_go/internal/cli/config.go")
result=$(echo "$json_payload" | bash hooks/post-write-guard.sh)
assert_not_contains "$result" "duplicate filename" "Go: same basename across different packages does not warn"
rm -rf "$tmp_repo_go"

# Non-Go (Python) preserves same-name detection — regression guard for the Go-only carve-out.
tmp_repo_py_check="$(mktemp -d)"
git -C "$tmp_repo_py_check" init -q
mkdir -p "$tmp_repo_py_check/pkg_a" "$tmp_repo_py_check/pkg_b"
cat >"$tmp_repo_py_check/pkg_a/utils.py" <<'EOF'
def alpha():
    return 1
EOF
json_payload=$(printf '{"tool_input":{"file_path":"%s","content":"def beta():\\n    return 2"}}' "$tmp_repo_py_check/pkg_b/utils.py")
result=$(echo "$json_payload" | bash hooks/post-write-guard.sh)
assert_contains "$result" "duplicate filename" "Python: same basename across packages still warns (Go-only carve-out)"
rm -rf "$tmp_repo_py_check"

# Runtime failures must remain visible even when the fallback log write also
# fails, because PostToolUse is review-only and should not fail silently.
tmp_repo_runtime_fail="$(mktemp -d)"
git -C "$tmp_repo_runtime_fail" init -q
tmp_log_dir="$(mktemp -d)"
locked_log="$tmp_log_dir/events.jsonl"
mkdir "${locked_log}.lock.d"
json_payload=$(printf '{"tool_input":{"file_path":"%s","content":"# x"}}' "$tmp_repo_runtime_fail/README.md")
result=$(echo "$json_payload" \
  | VIBEGUARD_PROJECT_LOG_DIR="$tmp_log_dir" \
    VIBEGUARD_LOG_FILE="$locked_log" \
    VIBEGUARD_LOG_LOCK_ATTEMPTS=1 \
    VIBEGUARD_LOG_LOCK_SLEEP_SECONDS=0 \
    bash hooks/post-write-guard.sh 2>/dev/null)
assert_contains "$result" "post-write runtime check failed" "Runtime failure remains visible when fallback logging fails"
rm -rf "$tmp_repo_runtime_fail" "$tmp_log_dir"

# =========================================================

hook_test_finish

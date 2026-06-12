#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
hook_test_init

header "post-build-check.sh — build check"
# =========================================================

# Non-build language files (.py) should be allowed
result=$(echo '{"tool_input":{"file_path":"src/main.py"}}' | bash hooks/post-build-check.sh)
assert_not_contains "$result" "VIBEGUARD" "Non-build language (.py) release"

# .md files should be released
result=$(echo '{"tool_input":{"file_path":"README.md"}}' | bash hooks/post-build-check.sh)
assert_not_contains "$result" "VIBEGUARD" "Non-source files (.md) are allowed"
assert_contains "$(grep -R "skip: unsupported extension .md" "$VIBEGUARD_LOG_DIR" 2>/dev/null || true)" "skip: unsupported extension .md" "Unsupported extension records skip telemetry"

# Empty file_path is allowed
result=$(echo '{"tool_input":{"file_path":""}}' | bash hooks/post-build-check.sh)
assert_not_contains "$result" "VIBEGUARD" "Empty file_path is allowed"

# .json files should be released
result=$(echo '{"tool_input":{"file_path":"package.json"}}' | bash hooks/post-build-check.sh)
assert_not_contains "$result" "VIBEGUARD" "Non-build language (.json) release"

# JavaScript syntax errors should warn
tmp_js_bad="$(mktemp -d)"
cat >"$tmp_js_bad/bad.js" <<'EOF'
const value = ;
EOF
result=$(echo "{\"tool_input\":{\"file_path\":\"$tmp_js_bad/bad.js\"}}" | bash hooks/post-build-check.sh)
assert_contains "$result" "VIBEGUARD" "JavaScript syntax error triggers build check warning"
rm -rf "$tmp_js_bad"

# JavaScript should be allowed if the syntax is correct
tmp_js_ok="$(mktemp -d)"
cat >"$tmp_js_ok/good.js" <<'EOF'
const value = 1;
EOF
result=$(echo "{\"tool_input\":{\"file_path\":\"$tmp_js_ok/good.js\"}}" | bash hooks/post-build-check.sh)
assert_not_contains "$result" "VIBEGUARD" "JavaScript syntax is correct"
rm -rf "$tmp_js_ok"

# Missing language markers should be logged instead of silent-only exits
tmp_rs_no_marker="$(mktemp -d)"
cat >"$tmp_rs_no_marker/main.rs" <<'EOF'
fn main() {}
EOF
result=$(echo "{\"tool_input\":{\"file_path\":\"$tmp_rs_no_marker/main.rs\"}}" | bash hooks/post-build-check.sh)
assert_not_contains "$result" "VIBEGUARD" "Rust file without Cargo.toml is skipped"
assert_contains "$(grep -R "skip: missing Cargo.toml" "$VIBEGUARD_LOG_DIR" 2>/dev/null || true)" "skip: missing Cargo.toml" "Missing Cargo.toml records skip telemetry"
rm -rf "$tmp_rs_no_marker"

# Build commands must be bounded by a hook-level timeout
tmp_js_timeout="$(mktemp -d)"
mkdir -p "$tmp_js_timeout/bin"
cat >"$tmp_js_timeout/bin/node" <<'EOF'
#!/usr/bin/env bash
sleep 5
EOF
chmod +x "$tmp_js_timeout/bin/node"
cat >"$tmp_js_timeout/slow.js" <<'EOF'
const value = 1;
EOF
result=$(PATH="$tmp_js_timeout/bin:$PATH" VIBEGUARD_POST_BUILD_TIMEOUT=1 bash -c "echo '{\"tool_input\":{\"file_path\":\"$tmp_js_timeout/slow.js\"}}' | bash hooks/post-build-check.sh")
assert_contains "$result" "timeout after 1s" "Post-build check reports timeout visibly"
assert_contains "$(grep -R "post-build-check timeout after 1s" "$VIBEGUARD_LOG_DIR" 2>/dev/null || true)" "post-build-check timeout after 1s" "Post-build timeout records telemetry"
rm -rf "$tmp_js_timeout"

# Build commands that fail without stderr/stdout should still be visible.
tmp_js_empty_fail="$(mktemp -d)"
mkdir -p "$tmp_js_empty_fail/bin"
cat >"$tmp_js_empty_fail/bin/node" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
chmod +x "$tmp_js_empty_fail/bin/node"
cat >"$tmp_js_empty_fail/fail.js" <<'EOF'
const value = 1;
EOF
result=$(PATH="$tmp_js_empty_fail/bin:$PATH" bash -c "echo '{\"tool_input\":{\"file_path\":\"$tmp_js_empty_fail/fail.js\"}}' | bash hooks/post-build-check.sh")
assert_contains "$result" "failed with exit status 7" "Post-build command failure without output is visible"
rm -rf "$tmp_js_empty_fail"

# Repeated checks for the same unchanged project should reuse a short-lived cache,
# but changing the checked file must invalidate the cache and surface failures.
tmp_js_cache="$(mktemp -d)"
mkdir -p "$tmp_js_cache/bin"
cat >"$tmp_js_cache/bin/node" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${POST_BUILD_NODE_LOG:?}"
target=""
for arg in "$@"; do
  target="$arg"
done
if grep -q "BROKEN" "$target"; then
  printf '%s\n' "SyntaxError: broken fixture" >&2
  exit 1
fi
exit 0
EOF
chmod +x "$tmp_js_cache/bin/node"
cat >"$tmp_js_cache/cached.js" <<'EOF'
const value = 1;
EOF
cache_node_log="$tmp_js_cache/node.log"
cache_env=(PATH="$tmp_js_cache/bin:$PATH" POST_BUILD_NODE_LOG="$cache_node_log" VIBEGUARD_POST_BUILD_CACHE_TTL=60)
result=$(env "${cache_env[@]}" bash -c "echo '{\"tool_input\":{\"file_path\":\"$tmp_js_cache/cached.js\"}}' | bash hooks/post-build-check.sh")
assert_not_contains "$result" "VIBEGUARD" "Initial post-build cache fixture passes"
result=$(env "${cache_env[@]}" bash -c "echo '{\"tool_input\":{\"file_path\":\"$tmp_js_cache/cached.js\"}}' | bash hooks/post-build-check.sh")
assert_not_contains "$result" "VIBEGUARD" "Unchanged post-build cache fixture reuses pass"
assert_occurrences "$(cat "$cache_node_log")" "--check" 1 "Unchanged post-build check reuses cached pass result"
cat >"$tmp_js_cache/cached.js" <<'EOF'
const value = BROKEN;
EOF
result=$(env "${cache_env[@]}" bash -c "echo '{\"tool_input\":{\"file_path\":\"$tmp_js_cache/cached.js\"}}' | bash hooks/post-build-check.sh")
assert_contains "$result" "VIBEGUARD" "Changed post-build cache fixture reruns and surfaces failure"
result=$(env "${cache_env[@]}" bash -c "echo '{\"tool_input\":{\"file_path\":\"$tmp_js_cache/cached.js\"}}' | bash hooks/post-build-check.sh")
assert_contains "$result" "VIBEGUARD" "Cached failing post-build result remains visible"
assert_occurrences "$(cat "$cache_node_log")" "--check" 2 "Changed worktree invalidates post-build cache once"
rm -rf "$tmp_js_cache"

# =========================================================

hook_test_finish

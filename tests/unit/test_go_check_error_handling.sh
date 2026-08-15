#!/usr/bin/env bash
# Unit tests for guards/go/check_error_handling.sh (GO-01)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="${REPO_DIR}/guards/go/check_error_handling.sh"

PASS=0; FAIL=0; TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }

assert_ok() {
  local desc="$1"; shift; TOTAL=$((TOTAL+1))
  if "$@" >/dev/null 2>&1; then green "$desc"; PASS=$((PASS+1))
  else red "$desc (expected exit 0)"; FAIL=$((FAIL+1)); fi
}

assert_fail() {
  local desc="$1"; shift; TOTAL=$((TOTAL+1))
  if "$@" >/dev/null 2>&1; then red "$desc (expected non-zero)"; FAIL=$((FAIL+1))
  else green "$desc"; PASS=$((PASS+1)); fi
}

assert_output_contains() {
  local desc="$1" expected="$2"; shift 2; TOTAL=$((TOTAL+1))
  local out; out=$("$@" 2>&1 || true)
  if echo "$out" | grep -qF "$expected"; then green "$desc"; PASS=$((PASS+1))
  else red "$desc (missing: $expected)"; FAIL=$((FAIL+1)); fi
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

printf '\n=== check_error_handling (GO-01) ===\n'

# --- FAIL: error assigned to _ (discarded) ---
proj_discard="${tmpdir}/fail_discard_error"
mkdir -p "${proj_discard}"
cat > "${proj_discard}/main.go" <<'EOF'
package main

import "os"

func main() {
    _ = os.Remove("/tmp/old-file.txt")
}
EOF
assert_fail "discarded error fails --strict" bash "$GUARD" --strict "$proj_discard"
assert_output_contains "output contains GO-01 tag" "[GO-01]" bash "$GUARD" --strict "$proj_discard"

# --- FAIL: multi-return regular assignment both discarded (_, _ = CALL) ---
proj_multi_assign="${tmpdir}/fail_multi_assign"
mkdir -p "${proj_multi_assign}"
cat > "${proj_multi_assign}/handler.go" <<'EOF'
package handler

import "strconv"

func Run() {
    _, _ = strconv.Atoi("123")
}
EOF
assert_fail "_, _ = CALL discards both values fails --strict" bash "$GUARD" --strict "$proj_multi_assign"

# --- FAIL: multiple return values both discarded (mixed _ := and _ =) ---
proj_multi="${tmpdir}/fail_multi_discard"
mkdir -p "${proj_multi}"
cat > "${proj_multi}/handler.go" <<'EOF'
package handler

import (
    "os"
    "strconv"
)

func Run() {
    _, _ = strconv.Atoi("123")
    _ = os.Setenv("KEY", "value")
}
EOF
assert_fail "multiple discarded values fails --strict" bash "$GUARD" --strict "$proj_multi"

# --- PASS: error properly checked ---
proj_checked="${tmpdir}/pass_checked"
mkdir -p "${proj_checked}"
cat > "${proj_checked}/main.go" <<'EOF'
package main

import (
    "fmt"
    "os"
)

func main() {
    if err := os.Remove("/tmp/old-file.txt"); err != nil {
        fmt.Fprintf(os.Stderr, "remove failed: %v\n", err)
    }
}
EOF
assert_ok "properly checked error passes" bash "$GUARD" --strict "$proj_checked"

# --- PASS: error returned up the call stack ---
proj_return="${tmpdir}/pass_return_err"
mkdir -p "${proj_return}"
cat > "${proj_return}/store.go" <<'EOF'
package store

import (
    "fmt"
    "os"
)

func DeleteFile(path string) error {
    if err := os.Remove(path); err != nil {
        return fmt.Errorf("delete %s: %w", path, err)
    }
    return nil
}
EOF
assert_ok "error returned up the stack passes" bash "$GUARD" --strict "$proj_return"

# --- PASS: blank identifier assigned a non-call value is not an error-return pattern ---
proj_value="${tmpdir}/pass_ordinary_value"
mkdir -p "$proj_value"
cat > "${proj_value}/value.go" <<'EOF'
package value
func Ignore(value int) { _ = value }
EOF
assert_ok "ordinary value assigned to blank identifier passes" bash "$GUARD" --strict "$proj_value"

# --- FAIL: discarded calls inside inline blocks and generic calls are detected ---
proj_inline_generic="${tmpdir}/fail_inline_generic"
mkdir -p "$proj_inline_generic"
cat > "${proj_inline_generic}/discard.go" <<'EOF'
package discard
func load[T any]() error { return nil }
func Cleanup(stale bool) { if stale { _ = load[map[string]int]() } }
EOF
assert_fail "inline generic discarded call fails --strict" bash "$GUARD" --strict "$proj_inline_generic"

# --- FAIL: gofmt preserves a line break between assignment and call ---
proj_multiline="${tmpdir}/fail_multiline_discard"
mkdir -p "$proj_multiline"
cat > "${proj_multiline}/discard.go" <<'EOF'
package discard
func cleanup() error { return nil }
func Cleanup() {
    _ =
        cleanup()
}
EOF
assert_fail "multiline discarded call fails --strict" bash "$GUARD" --strict "$proj_multiline"

# --- FAIL: selector dots may be followed by a physical line break ---
proj_selector_break="${tmpdir}/fail_selector_break"
mkdir -p "$proj_selector_break"
cat > "${proj_selector_break}/discard.go" <<'EOF'
package discard
type Client struct{}
func (*Client) Close() error { return nil }
func Cleanup(client *Client) {
    _ = client.
        Close()
}
EOF
assert_fail "discarded call with a line break after selector dot fails --strict" \
  bash "$GUARD" --strict "$proj_selector_break"

# --- FAIL: labels and case clauses can precede blank assignments ---
proj_labeled="${tmpdir}/fail_labeled_discard"
mkdir -p "$proj_labeled"
cat > "${proj_labeled}/discard.go" <<'EOF'
package discard
func cleanup() error { return nil }
func Cleanup(value int) {
    switch value { case 1: _ = cleanup() }
retry: _ = cleanup()
    if value > 1 { goto retry }
}
EOF
assert_fail "discarded calls after case clauses and labels fail --strict" \
  bash "$GUARD" --strict "$proj_labeled"

# --- FAIL: parenthesized callees still discard returned errors ---
proj_parenthesized="${tmpdir}/fail_parenthesized_callee"
mkdir -p "$proj_parenthesized"
cat > "${proj_parenthesized}/discard.go" <<'EOF'
package discard
type Client struct{}
func (*Client) Close() error { return nil }
func Cleanup(client *Client, cleanup func() error) {
    _ = (*client).Close()
    _ = (cleanup)()
}
EOF
assert_fail "parenthesized discarded calls fail --strict" \
  bash "$GUARD" --strict "$proj_parenthesized"

# --- PASS: Go raw strings never become executable scanner input ---
proj_raw_string="${tmpdir}/pass_raw_string"
mkdir -p "$proj_raw_string"
cat > "${proj_raw_string}/raw.go" <<'EOF'
package raw
const template = `${
_ = fake()
}`
func Keep() string { return template }
EOF
assert_ok "discard syntax inside Go raw strings passes" bash "$GUARD" --strict "$proj_raw_string"

# --- PASS: call-like text in block comments is ignored ---
proj_comment="${tmpdir}/pass_block_comment"
mkdir -p "$proj_comment"
cat > "${proj_comment}/comment.go" <<'EOF'
package comment
/*
_ = os.Remove("old")
*/
func Clean() {}
EOF
assert_ok "discarded call text inside block comment passes" bash "$GUARD" --strict "$proj_comment"

# --- FAIL: Go block comments end at the first closing delimiter ---
proj_non_nested_comment="${tmpdir}/fail_non_nested_block_comment"
mkdir -p "$proj_non_nested_comment"
cat > "${proj_non_nested_comment}/comment.go" <<'EOF'
package comment
func cleanup() error { return nil }
func Clean() {
    /* text /* marker */
    _ = cleanup()
}
EOF
assert_fail "discard after non-nested Go block comment fails --strict" \
  bash "$GUARD" --strict "$proj_non_nested_comment"

# --- PASS: test files are excluded ---
proj_test="${tmpdir}/pass_test_excluded"
mkdir -p "${proj_test}"
cat > "${proj_test}/handler_test.go" <<'EOF'
package handler

import "testing"

func TestRun(t *testing.T) {
    _ = doSomething()
}
EOF
assert_ok "discarded error in _test.go is excluded" bash "$GUARD" --strict "$proj_test"

# --- FAIL: staged mode works when bash mapfile is unavailable ---
proj_staged_no_mapfile="${tmpdir}/fail_staged_no_mapfile"
mkdir -p "${proj_staged_no_mapfile}"
proj_staged_no_mapfile="$(cd "${proj_staged_no_mapfile}" && pwd -P)"
git -C "${proj_staged_no_mapfile}" init -q
cat > "${proj_staged_no_mapfile}/main.go" <<'EOF'
package main

import "os"

func main() {
    _ = os.Remove("/tmp/old-file.txt")
}
EOF
git -C "${proj_staged_no_mapfile}" add main.go
staged_no_mapfile_list="${tmpdir}/go_staged_files.txt"
printf '%s\n' "${proj_staged_no_mapfile}/main.go" > "$staged_no_mapfile_list"
disable_mapfile_env="${tmpdir}/disable_mapfile.bashenv"
printf '%s\n' 'enable -n mapfile 2>/dev/null || true' > "$disable_mapfile_env"
ast_grep_stub_dir="${tmpdir}/ast_grep_stub_go"
mkdir -p "$ast_grep_stub_dir"
cat > "$ast_grep_stub_dir/ast-grep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target="${!#}"
printf '[{"file":"%s","range":{"start":{"line":5}},"message":"stub discarded error"}]\n' "$target"
EOF
chmod +x "$ast_grep_stub_dir/ast-grep"
assert_output_contains "staged mode without mapfile uses Rust target collection" "[GO-01]" \
  env PATH="$ast_grep_stub_dir:$PATH" BASH_ENV="$disable_mapfile_env" VIBEGUARD_STAGED_FILES="$staged_no_mapfile_list" \
  bash "$GUARD" --strict "$proj_staged_no_mapfile"

# --- PASS: code with no blank identifier assignments ---
proj_clean2="${tmpdir}/pass_clean2"
mkdir -p "${proj_clean2}"
cat > "${proj_clean2}/util.go" <<'EOF'
package util

import "strings"

func Join(items []string) string {
    return strings.Join(items, ", ")
}

func Count(items []string) int {
    return len(items)
}
EOF
assert_ok "code without blank identifier assignments passes" bash "$GUARD" --strict "$proj_clean2"

echo
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' "$TOTAL" "$PASS" "$FAIL"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0

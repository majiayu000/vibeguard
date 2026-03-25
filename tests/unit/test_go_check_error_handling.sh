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

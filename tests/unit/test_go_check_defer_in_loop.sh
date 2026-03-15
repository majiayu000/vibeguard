#!/usr/bin/env bash
# Unit tests for guards/go/check_defer_in_loop.sh (GO-08)
#
# NOTE: The guard uses awk /^\s*for\s/ and /^\s*defer\s/ patterns. The \s shorthand
# requires gawk (GNU awk). On macOS with system awk, detection tests are skipped.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="${REPO_DIR}/guards/go/check_defer_in_loop.sh"

PASS=0; FAIL=0; SKIP=0; TOTAL=0

green()  { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()    { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
yellow() { printf '\033[33m  SKIP: %s\033[0m\n' "$1"; }

# Check whether awk supports \s regex shorthand (requires gawk)
AWK_SUPPORTS_SHORTHAND=false
if printf 'for x\n' | awk '/^\s*for\s/ { found=1 } END { exit !found }' 2>/dev/null; then
  AWK_SUPPORTS_SHORTHAND=true
fi

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

# assert_fail_or_skip: only runs detection test if awk supports \s shorthand
assert_fail_or_skip() {
  local desc="$1"; shift
  if [[ "$AWK_SUPPORTS_SHORTHAND" == "false" ]]; then
    SKIP=$((SKIP+1))
    yellow "$desc (skipped: awk lacks \\s support — use gawk)"
    return
  fi
  assert_fail "$desc" "$@"
}

assert_output_contains() {
  local desc="$1" expected="$2"; shift 2; TOTAL=$((TOTAL+1))
  local out; out=$("$@" 2>&1 || true)
  if echo "$out" | grep -qF "$expected"; then green "$desc"; PASS=$((PASS+1))
  else red "$desc (missing: $expected)"; FAIL=$((FAIL+1)); fi
}

assert_output_contains_or_skip() {
  local desc="$1" expected="$2"; shift 2
  if [[ "$AWK_SUPPORTS_SHORTHAND" == "false" ]]; then
    SKIP=$((SKIP+1))
    yellow "$desc (skipped: awk lacks \\s support)"
    return
  fi
  assert_output_contains "$desc" "$expected" "$@"
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

printf '\n=== check_defer_in_loop (GO-08) ===\n'

# --- FAIL: defer inside a for range loop ---
proj_range="${tmpdir}/fail_defer_in_range"
mkdir -p "${proj_range}"
cat > "${proj_range}/files.go" <<'EOF'
package files

import "os"

func ProcessFiles(paths []string) error {
    for _, path := range paths {
        f, err := os.Open(path)
        if err != nil {
            return err
        }
        defer f.Close()
        // process f...
    }
    return nil
}
EOF
assert_fail_or_skip "defer inside for range fails --strict" bash "$GUARD" --strict "$proj_range"
assert_output_contains_or_skip "output contains GO-08 tag" "[GO-08]" bash "$GUARD" --strict "$proj_range"

# --- FAIL: defer inside a traditional for loop ---
proj_traditional="${tmpdir}/fail_defer_traditional"
mkdir -p "${proj_traditional}"
cat > "${proj_traditional}/batch.go" <<'EOF'
package batch

import (
    "database/sql"
)

func ProcessBatch(db *sql.DB, ids []int) error {
    for i := 0; i < len(ids); i++ {
        rows, err := db.Query("SELECT * FROM items WHERE id = ?", ids[i])
        if err != nil {
            return err
        }
        defer rows.Close()
    }
    return nil
}
EOF
assert_fail_or_skip "defer inside traditional for loop fails --strict" bash "$GUARD" --strict "$proj_traditional"

# --- PASS: defer outside loop (in function scope) ---
proj_outside="${tmpdir}/pass_defer_outside"
mkdir -p "${proj_outside}"
cat > "${proj_outside}/reader.go" <<'EOF'
package reader

import "os"

func ReadFile(path string) ([]byte, error) {
    f, err := os.Open(path)
    if err != nil {
        return nil, err
    }
    defer f.Close()

    buf := make([]byte, 1024)
    n, err := f.Read(buf)
    if err != nil {
        return nil, err
    }
    return buf[:n], nil
}
EOF
assert_ok "defer outside loop passes" bash "$GUARD" --strict "$proj_outside"

# --- PASS: no defer at all ---
proj_no_defer="${tmpdir}/pass_no_defer"
mkdir -p "${proj_no_defer}"
cat > "${proj_no_defer}/calc.go" <<'EOF'
package calc

func Sum(nums []int) int {
    total := 0
    for _, n := range nums {
        total += n
    }
    return total
}
EOF
assert_ok "no defer at all passes" bash "$GUARD" --strict "$proj_no_defer"

# --- PASS: test files excluded ---
proj_test="${tmpdir}/pass_test_excluded"
mkdir -p "${proj_test}"
cat > "${proj_test}/files_test.go" <<'EOF'
package files

import (
    "os"
    "testing"
)

func TestProcessFiles(t *testing.T) {
    paths := []string{"/tmp/a", "/tmp/b"}
    for _, p := range paths {
        f, _ := os.Create(p)
        defer f.Close()
    }
}
EOF
assert_ok "defer in loop in _test.go is excluded" bash "$GUARD" --strict "$proj_test"

# --- PASS: non-strict mode exits 0 with defer-in-loop ---
proj_nonstrict="${tmpdir}/pass_nonstrict"
mkdir -p "${proj_nonstrict}"
cat > "${proj_nonstrict}/resource.go" <<'EOF'
package resource

import "os"

func OpenAll(paths []string) {
    for _, p := range paths {
        f, _ := os.Open(p)
        defer f.Close()
    }
}
EOF
assert_ok "defer in loop without --strict exits 0" bash "$GUARD" "$proj_nonstrict"

echo
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m  Skip: \033[33m%d\033[0m\n' "$TOTAL" "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0

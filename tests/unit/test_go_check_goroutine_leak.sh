#!/usr/bin/env bash
# Unit tests for guards/go/check_goroutine_leak.sh (GO-02)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="${REPO_DIR}/guards/go/check_goroutine_leak.sh"

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

printf '\n=== check_goroutine_leak (GO-02) ===\n'

# --- FAIL: go func() launch without exit mechanism ---
proj_gofunc="${tmpdir}/fail_goroutine"
mkdir -p "${proj_gofunc}"
cat > "${proj_gofunc}/worker.go" <<'EOF'
package worker

func StartWorker() {
    go func() {
        for {
            doWork()
        }
    }()
}

func doWork() {}
EOF
assert_fail "go func() launch fails --strict" bash "$GUARD" --strict "$proj_gofunc"
assert_output_contains "output contains GO-02 tag" "[GO-02]" bash "$GUARD" --strict "$proj_gofunc"

# --- FAIL: naked infinite for {} loop ---
proj_loop="${tmpdir}/fail_infinite_loop"
mkdir -p "${proj_loop}"
cat > "${proj_loop}/server.go" <<'EOF'
package server

func Run() {
    for {
        handleConnection()
    }
}

func handleConnection() {}
EOF
assert_fail "infinite for {} loop fails --strict" bash "$GUARD" --strict "$proj_loop"
assert_output_contains "output contains GO-02/loop tag" "[GO-02/loop]" bash "$GUARD" --strict "$proj_loop"

# --- FAIL: named function goroutine launch ---
proj_named="${tmpdir}/fail_named_goroutine"
mkdir -p "${proj_named}"
cat > "${proj_named}/main.go" <<'EOF'
package main

func startBackground() {
    go processQueue()
}

func processQueue() {}
EOF
assert_fail "named goroutine launch fails --strict" bash "$GUARD" --strict "$proj_named"

# --- PASS: no goroutines at all ---
proj_clean="${tmpdir}/pass_no_goroutines"
mkdir -p "${proj_clean}"
cat > "${proj_clean}/math.go" <<'EOF'
package math

func Add(a, b int) int { return a + b }
func Multiply(a, b int) int { return a * b }
EOF
assert_ok "no goroutines passes" bash "$GUARD" --strict "$proj_clean"

# --- PASS: test files excluded ---
proj_test="${tmpdir}/pass_test_excluded"
mkdir -p "${proj_test}"
cat > "${proj_test}/worker_test.go" <<'EOF'
package worker

import "testing"

func TestStartWorker(t *testing.T) {
    go func() {
        for {
            t.Log("running")
        }
    }()
}
EOF
assert_ok "goroutine in _test.go is excluded" bash "$GUARD" --strict "$proj_test"

# --- PASS: non-strict mode exits 0 with goroutines ---
proj_nonstrict="${tmpdir}/pass_nonstrict"
mkdir -p "${proj_nonstrict}"
cat > "${proj_nonstrict}/bg.go" <<'EOF'
package bg

func Start() { go process() }
func process() {}
EOF
assert_ok "goroutine without --strict exits 0" bash "$GUARD" "$proj_nonstrict"

echo
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' "$TOTAL" "$PASS" "$FAIL"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0

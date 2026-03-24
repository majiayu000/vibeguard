#!/usr/bin/env bash
# Unit tests for guards/rust/check_nested_locks.sh (RS-01)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="${REPO_DIR}/guards/rust/check_nested_locks.sh"

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

printf '\n=== check_nested_locks (RS-01) ===\n'

# --- FAIL: function acquires 3 locks (> 2 triggers the guard) ---
proj="${tmpdir}/fail_three_locks"
mkdir -p "${proj}/src"
cat > "${proj}/src/state.rs" <<'EOF'
use std::sync::{Arc, Mutex, RwLock};

pub struct State {
    a: Arc<Mutex<String>>,
    b: Arc<RwLock<String>>,
    c: Arc<Mutex<u32>>,
}

impl State {
    pub fn update_all(&self) {
        let _a = self.a.lock();
        let _b = self.b.write();
        let _c = self.c.lock();
        // ABBA deadlock risk
    }
}
EOF
assert_fail "three lock acquisitions fails --strict" bash "$GUARD" --strict "$proj"
assert_output_contains "output contains RS-01 tag" "[RS-01]" bash "$GUARD" --strict "$proj"

# --- FAIL: four locks in one function ---
proj2="${tmpdir}/fail_four_locks"
mkdir -p "${proj2}/src"
cat > "${proj2}/src/coordinator.rs" <<'EOF'
use std::sync::{Mutex, RwLock};
struct Coord { a: Mutex<i32>, b: Mutex<i32>, c: RwLock<i32>, d: Mutex<i32> }
impl Coord {
    fn sync_all(&self) {
        let _a = self.a.lock();
        let _b = self.b.lock();
        let _c = self.c.read();
        let _d = self.d.lock();
    }
}
EOF
assert_fail "four lock acquisitions fails --strict" bash "$GUARD" --strict "$proj2"

# --- PASS: function acquires only one lock ---
proj3="${tmpdir}/pass_single_lock"
mkdir -p "${proj3}/src"
cat > "${proj3}/src/safe.rs" <<'EOF'
use std::sync::Mutex;
struct Safe { data: Mutex<Vec<String>> }
impl Safe {
    pub fn push(&self, item: String) {
        let mut guard = self.data.lock().unwrap();
        guard.push(item);
    }
}
EOF
assert_ok "single lock acquisition passes" bash "$GUARD" --strict "$proj3"

# --- PASS: two locks (guard triggers at > 2, not >= 2) ---
proj4="${tmpdir}/pass_two_locks"
mkdir -p "${proj4}/src"
cat > "${proj4}/src/two.rs" <<'EOF'
use std::sync::{Mutex, RwLock};
struct Two { a: Mutex<i32>, b: RwLock<i32> }
impl Two {
    fn update(&self) {
        let _a = self.a.lock();
        let _b = self.b.read();
    }
}
EOF
assert_ok "two lock acquisitions passes (threshold is >2)" bash "$GUARD" --strict "$proj4"

# --- PASS: no lock calls at all ---
proj5="${tmpdir}/pass_no_locks"
mkdir -p "${proj5}/src"
cat > "${proj5}/src/simple.rs" <<'EOF'
pub fn add(a: i32, b: i32) -> i32 { a + b }
EOF
assert_ok "no lock calls passes" bash "$GUARD" --strict "$proj5"

# --- PASS: 3 locks but they're in separate functions ---
proj6="${tmpdir}/pass_separate_fns"
mkdir -p "${proj6}/src"
cat > "${proj6}/src/separate.rs" <<'EOF'
use std::sync::Mutex;
struct S { a: Mutex<i32>, b: Mutex<i32>, c: Mutex<i32> }
impl S {
    fn fn_a(&self) { let _g = self.a.lock(); }
    fn fn_b(&self) { let _g = self.b.lock(); }
    fn fn_c(&self) { let _g = self.c.lock(); }
}
EOF
assert_ok "locks split across separate functions passes" bash "$GUARD" --strict "$proj6"

echo
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' "$TOTAL" "$PASS" "$FAIL"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0

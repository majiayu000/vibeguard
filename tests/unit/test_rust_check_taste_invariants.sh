#!/usr/bin/env bash
# Unit tests for guards/rust/check_taste_invariants.sh (TASTE-*)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="${REPO_DIR}/guards/rust/check_taste_invariants.sh"

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

printf '\n=== check_taste_invariants (TASTE-*) ===\n'

# --- FAIL: TASTE-ANSI: hardcoded ANSI escape \x1b[ ---
proj_ansi="${tmpdir}/fail_ansi"
mkdir -p "${proj_ansi}/src"
# Use a literal backslash-x in the file (not shell escape)
printf 'fn colorize(s: &str) -> String {\n    format!("\\x1b[32m{}\\x1b[0m", s)\n}\n' \
  > "${proj_ansi}/src/ui.rs"
assert_fail "hardcoded \\x1b[ ANSI escape fails --strict" bash "$GUARD" --strict "$proj_ansi"
assert_output_contains "output contains TASTE-ANSI tag" "[TASTE-ANSI]" bash "$GUARD" --strict "$proj_ansi"

# --- FAIL: TASTE-ANSI: hardcoded ANSI escape \033[ ---
proj_ansi2="${tmpdir}/fail_ansi2"
mkdir -p "${proj_ansi2}/src"
printf 'fn bold(s: &str) -> String {\n    format!("\\033[1m{}\\033[0m", s)\n}\n' \
  > "${proj_ansi2}/src/display.rs"
assert_fail "hardcoded \\033[ ANSI escape fails --strict" bash "$GUARD" --strict "$proj_ansi2"

# --- FAIL: TASTE-ASYNC-UNWRAP: async fn + .unwrap() ---
proj_async="${tmpdir}/fail_async_unwrap"
mkdir -p "${proj_async}/src"
cat > "${proj_async}/src/handler.rs" <<'EOF'
pub async fn fetch_data(url: &str) -> String {
    reqwest::get(url).await.unwrap().text().await.unwrap()
}
EOF
assert_fail "async fn with unwrap() fails --strict" bash "$GUARD" --strict "$proj_async"
assert_output_contains "output contains TASTE-ASYNC-UNWRAP tag" "[TASTE-ASYNC-UNWRAP]" bash "$GUARD" --strict "$proj_async"

# --- FAIL: TASTE-PANIC-MSG: panic!() without message ---
proj_panic="${tmpdir}/fail_panic_no_msg"
mkdir -p "${proj_panic}/src"
cat > "${proj_panic}/src/lib.rs" <<'EOF'
pub fn validate(x: i32) {
    if x < 0 {
        panic!()
    }
}
EOF
assert_fail "panic!() without message fails --strict" bash "$GUARD" --strict "$proj_panic"
assert_output_contains "output contains TASTE-PANIC-MSG tag" "[TASTE-PANIC-MSG]" bash "$GUARD" --strict "$proj_panic"

# --- FAIL: panic!("") empty string ---
proj_panic2="${tmpdir}/fail_panic_empty"
mkdir -p "${proj_panic2}/src"
cat > "${proj_panic2}/src/lib.rs" <<'EOF'
pub fn check(flag: bool) {
    if !flag { panic!("") }
}
EOF
assert_fail "panic!(\"\") empty message fails --strict" bash "$GUARD" --strict "$proj_panic2"

# --- PASS: panic!() with a meaningful message ---
proj_panic_ok="${tmpdir}/pass_panic_with_msg"
mkdir -p "${proj_panic_ok}/src"
cat > "${proj_panic_ok}/src/lib.rs" <<'EOF'
pub fn must_be_positive(x: i32) {
    if x <= 0 {
        panic!("value must be positive, got {}", x)
    }
}
EOF
assert_ok "panic!() with message passes" bash "$GUARD" --strict "$proj_panic_ok"

# --- PASS: completely clean file ---
proj_clean="${tmpdir}/pass_clean"
mkdir -p "${proj_clean}/src"
cat > "${proj_clean}/src/lib.rs" <<'EOF'
use std::fmt;

pub struct Point { pub x: f64, pub y: f64 }

impl fmt::Display for Point {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "({}, {})", self.x, self.y)
    }
}

pub fn distance(a: &Point, b: &Point) -> f64 {
    ((a.x - b.x).powi(2) + (a.y - b.y).powi(2)).sqrt()
}
EOF
assert_ok "clean file passes all taste invariants" bash "$GUARD" --strict "$proj_clean"

echo
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' "$TOTAL" "$PASS" "$FAIL"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0

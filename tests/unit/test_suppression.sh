#!/usr/bin/env bash
# Unit tests for inline suppression comments (issue #29)
# Tests: // vibeguard-disable-next-line <RULE-ID> [-- reason]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RUST_GUARD="${REPO_DIR}/guards/rust/check_unwrap_in_prod.sh"
GO_GUARD="${REPO_DIR}/guards/go/check_error_handling.sh"
TS_GUARD="${REPO_DIR}/guards/typescript/check_any_abuse.sh"

PASS=0; FAIL=0; TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }

assert_ok() {
  local desc="$1"; shift; TOTAL=$((TOTAL+1))
  if "$@" >/dev/null 2>&1; then green "$desc"; PASS=$((PASS+1))
  else red "$desc (expected exit 0)"; FAIL=$((FAIL+1)); fi
}

assert_output_contains() {
  local desc="$1" expected="$2"; shift 2; TOTAL=$((TOTAL+1))
  local out; out=$("$@" 2>&1 || true)
  if echo "$out" | grep -qF "$expected"; then green "$desc"; PASS=$((PASS+1))
  else red "$desc (missing: $expected)"; FAIL=$((FAIL+1)); fi
}

assert_output_not_contains() {
  local desc="$1" unexpected="$2"; shift 2; TOTAL=$((TOTAL+1))
  local out; out=$("$@" 2>&1 || true)
  if echo "$out" | grep -qF "$unexpected"; then
    red "$desc (unexpected output found: $unexpected)"; FAIL=$((FAIL+1))
  else green "$desc"; PASS=$((PASS+1)); fi
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

printf '\n=== Suppression: RS-03 (Rust unwrap) ===\n'

# --- PASS: suppressed unwrap() with rule and reason ---
proj="${tmpdir}/rs03_suppressed"
mkdir -p "${proj}/src"
cat > "${proj}/src/main.rs" <<'EOF'
fn main() {
    // vibeguard-disable-next-line RS-03 -- Option guaranteed Some by initialization
    let val = std::env::var("HOME").unwrap();
    println!("{}", val);
}
EOF
assert_ok "suppressed RS-03 with reason exits 0 (--strict)" \
  bash "$RUST_GUARD" --strict "$proj"
assert_output_not_contains "suppressed line does not appear in output" "[RS-03]" \
  bash "$RUST_GUARD" --strict "$proj"

# --- PASS: suppressed unwrap() without reason ---
proj2="${tmpdir}/rs03_suppressed_noreason"
mkdir -p "${proj2}/src"
cat > "${proj2}/src/main.rs" <<'EOF'
fn main() {
    // vibeguard-disable-next-line RS-03
    let val = std::env::var("HOME").unwrap();
    println!("{}", val);
}
EOF
assert_ok "suppressed RS-03 without reason exits 0 (--strict)" \
  bash "$RUST_GUARD" --strict "$proj2"

# --- FAIL: unsuppressed unwrap() is still flagged ---
proj3="${tmpdir}/rs03_unsuppressed"
mkdir -p "${proj3}/src"
cat > "${proj3}/src/main.rs" <<'EOF'
fn main() {
    let val = std::env::var("HOME").unwrap();
    println!("{}", val);
}
EOF
assert_output_contains "unsuppressed RS-03 still appears in output" "[RS-03]" \
  bash "$RUST_GUARD" "$proj3"

# --- FAIL: wrong rule ID does not suppress ---
proj4="${tmpdir}/rs03_wrong_rule"
mkdir -p "${proj4}/src"
cat > "${proj4}/src/main.rs" <<'EOF'
fn main() {
    // vibeguard-disable-next-line RS-99 -- wrong rule
    let val = std::env::var("HOME").unwrap();
    println!("{}", val);
}
EOF
assert_output_contains "wrong rule ID does not suppress RS-03" "[RS-03]" \
  bash "$RUST_GUARD" "$proj4"

# --- PASS: suppression on same line does NOT suppress (must be previous line) ---
proj5="${tmpdir}/rs03_same_line"
mkdir -p "${proj5}/src"
cat > "${proj5}/src/main.rs" <<'EOF'
fn main() {
    let val = std::env::var("HOME").unwrap(); // vibeguard-disable-next-line RS-03
    println!("{}", val);
}
EOF
assert_output_contains "disable comment on same line does not suppress" "[RS-03]" \
  bash "$RUST_GUARD" "$proj5"

# --- PASS: multiple unwraps, only one suppressed ---
proj6="${tmpdir}/rs03_partial"
mkdir -p "${proj6}/src"
cat > "${proj6}/src/main.rs" <<'EOF'
fn main() {
    // vibeguard-disable-next-line RS-03 -- guaranteed by prior check
    let a = std::env::var("HOME").unwrap();
    let b = std::env::var("PATH").unwrap();
    println!("{} {}", a, b);
}
EOF
assert_output_contains "second unsuppressed unwrap still appears" "[RS-03]" \
  bash "$RUST_GUARD" "$proj6"

printf '\n=== Suppression: GO-01 (Go error handling) ===\n'

# --- PASS: suppressed error discard ---
goproj="${tmpdir}/go01_suppressed"
mkdir -p "${goproj}/pkg"
cat > "${goproj}/pkg/main.go" <<'EOF'
package main

import "os"

func main() {
	// vibeguard-disable-next-line GO-01 -- cleanup close, error irrelevant
	_ = os.Remove("/tmp/test.txt")
}
EOF
assert_ok "suppressed GO-01 exits 0 (--strict)" \
  bash "$GO_GUARD" --strict "$goproj"
assert_output_not_contains "suppressed GO-01 not in output" "[GO-01]" \
  bash "$GO_GUARD" --strict "$goproj"

# --- FAIL: unsuppressed error discard is still flagged ---
goproj2="${tmpdir}/go01_unsuppressed"
mkdir -p "${goproj2}/pkg"
cat > "${goproj2}/pkg/main.go" <<'EOF'
package main

import "os"

func main() {
	_ = os.Remove("/tmp/test.txt")
}
EOF
assert_output_contains "unsuppressed GO-01 still appears" "[GO-01]" \
  bash "$GO_GUARD" "$goproj2"

printf '\n=== Suppression: TS-01 (TypeScript any) ===\n'

# --- PASS: suppressed any type ---
tsproj="${tmpdir}/ts01_suppressed"
mkdir -p "${tsproj}/src"
cat > "${tsproj}/src/index.ts" <<'EOF'
// vibeguard-disable-next-line TS-01 -- third-party API returns any
const response: any = {};
export default response;
EOF
assert_ok "suppressed TS-01 exits 0 (--strict)" \
  bash "$TS_GUARD" --strict "$tsproj"
assert_output_not_contains "suppressed TS-01 finding not in output" "any 类型使用" \
  bash "$TS_GUARD" --strict "$tsproj"

# --- FAIL: unsuppressed any type is still flagged ---
tsproj2="${tmpdir}/ts01_unsuppressed"
mkdir -p "${tsproj2}/src"
cat > "${tsproj2}/src/index.ts" <<'EOF'
const response: any = {};
export default response;
EOF
assert_output_contains "unsuppressed TS-01 still appears" "[TS-01]" \
  bash "$TS_GUARD" "$tsproj2"

# --- PASS: wrong rule does not suppress TS-01 ---
tsproj3="${tmpdir}/ts01_wrong_rule"
mkdir -p "${tsproj3}/src"
cat > "${tsproj3}/src/index.ts" <<'EOF'
// vibeguard-disable-next-line TS-99 -- wrong rule
const response: any = {};
export default response;
EOF
assert_output_contains "wrong rule does not suppress TS-01" "[TS-01]" \
  bash "$TS_GUARD" "$tsproj3"

printf '\n=== Issue 1: loose regex — directive mentioned mid-comment must NOT suppress ===\n'

# A comment that merely mentions the directive phrase (not as the first token
# after "//") must not be treated as a suppression instruction.
proj_mention="${tmpdir}/rs03_mention_only"
mkdir -p "${proj_mention}/src"
cat > "${proj_mention}/src/main.rs" <<'EOF'
fn main() {
    // Do NOT add vibeguard-disable-next-line RS-03 without a good reason
    let val = std::env::var("HOME").unwrap();
    println!("{}", val);
}
EOF
assert_output_contains "directive mentioned mid-comment still flags RS-03" "[RS-03]" \
  bash "$RUST_GUARD" "$proj_mention"

printf '\n=== Issue 2: staged vs working-tree mismatch ===\n'

# Build a tiny git repo so we can exercise pre-commit mode properly.
git_proj="${tmpdir}/rs03_staged_mismatch"
mkdir -p "${git_proj}/src"
(
  cd "${git_proj}"
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"

  # Initial commit — clean file, no violation.
  cat > src/main.rs <<'RUST'
fn main() {
    println!("hello");
}
RUST
  git add src/main.rs
  git commit -q -m "init"

  # Stage a version that has the violation but NO suppression comment.
  cat > src/main.rs <<'RUST'
fn main() {
    let val = std::env::var("HOME").unwrap();
    println!("{}", val);
}
RUST
  git add src/main.rs

  # Now add a suppression comment in the working tree only (do NOT re-stage).
  cat > src/main.rs <<'RUST'
fn main() {
    // vibeguard-disable-next-line RS-03 -- only in working tree, not staged
    let val = std::env::var("HOME").unwrap();
    println!("{}", val);
}
RUST
)

staged_list="${tmpdir}/staged_list_mismatch.txt"
printf '%s/src/main.rs\n' "${git_proj}" > "${staged_list}"
out_mismatch=$(cd "${git_proj}" && VIBEGUARD_STAGED_FILES="${staged_list}" bash "$RUST_GUARD" 2>&1 || true)

TOTAL=$((TOTAL+1))
if echo "$out_mismatch" | grep -qF '[RS-03]'; then
  green "unstaged suppression does not bypass staged violation"; PASS=$((PASS+1))
else
  red "unstaged suppression does not bypass staged violation (expected [RS-03] but got none)"; FAIL=$((FAIL+1))
fi

# Positive case: suppression comment IS staged → violation must be suppressed.
git_proj2="${tmpdir}/rs03_staged_match"
mkdir -p "${git_proj2}/src"
(
  cd "${git_proj2}"
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"

  # Initial commit — clean file.
  cat > src/main.rs <<'RUST'
fn main() {
    println!("hello");
}
RUST
  git add src/main.rs
  git commit -q -m "init"

  # Stage both the suppression comment and the violation together.
  cat > src/main.rs <<'RUST'
fn main() {
    // vibeguard-disable-next-line RS-03 -- staged alongside the call
    let val = std::env::var("HOME").unwrap();
    println!("{}", val);
}
RUST
  git add src/main.rs
)

staged_list2="${tmpdir}/staged_list_match.txt"
printf '%s/src/main.rs\n' "${git_proj2}" > "${staged_list2}"
out_match=$(cd "${git_proj2}" && VIBEGUARD_STAGED_FILES="${staged_list2}" bash "$RUST_GUARD" 2>&1 || true)

TOTAL=$((TOTAL+1))
if echo "$out_match" | grep -qF '[RS-03]'; then
  red "staged suppression comment should suppress violation"; FAIL=$((FAIL+1))
else
  green "staged suppression comment correctly suppresses violation"; PASS=$((PASS+1))
fi

echo
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' "$TOTAL" "$PASS" "$FAIL"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0

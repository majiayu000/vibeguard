#!/usr/bin/env bash
# Unit tests for guards/rust/check_unwrap_in_prod.sh (RS-03)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="${REPO_DIR}/guards/rust/check_unwrap_in_prod.sh"

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

assert_output_not_contains() {
  local desc="$1" unexpected="$2"; shift 2; TOTAL=$((TOTAL+1))
  local out; out=$("$@" 2>&1 || true)
  if ! echo "$out" | grep -qF "$unexpected"; then green "$desc"; PASS=$((PASS+1))
  else red "$desc (unexpected: $unexpected)"; FAIL=$((FAIL+1)); fi
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

runtime_wrapper="${tmpdir}/runtime-wrapper"
cat > "$runtime_wrapper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec cargo run --quiet --manifest-path "${VG_TEST_RUNTIME_MANIFEST:?}" -- "$@"
EOF
chmod +x "$runtime_wrapper"

failing_runtime="${tmpdir}/failing-runtime"
cat > "$failing_runtime" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$failing_runtime"

run_guard_with_runtime() {
  local runtime="$1"; shift
  env \
    VG_TEST_RUNTIME_MANIFEST="${REPO_DIR}/vibeguard-runtime/Cargo.toml" \
    VIBEGUARD_RUNTIME="$runtime" \
    bash "$GUARD" "$@"
}

printf '\n=== check_unwrap_in_prod (RS-03) ===\n'

# --- FAIL: .unwrap() in production code ---
proj="${tmpdir}/fail_unwrap"
mkdir -p "${proj}/src"
cat > "${proj}/src/main.rs" <<'EOF'
fn main() {
    let val = std::env::var("HOME").unwrap();
    println!("{}", val);
}
EOF
assert_fail "unwrap() in prod code fails --strict" bash "$GUARD" --strict "$proj"
assert_output_contains "output contains RS-03 tag" "[RS-03]" bash "$GUARD" --strict "$proj"

# --- FAIL: .expect() in production code ---
proj2="${tmpdir}/fail_expect"
mkdir -p "${proj2}/src"
cat > "${proj2}/src/lib.rs" <<'EOF'
pub fn load() -> String {
    std::fs::read_to_string("config.toml").expect("config missing")
}
EOF
assert_fail "expect() in prod code fails --strict" bash "$GUARD" --strict "$proj2"

# --- PASS: only safe unwrap_or variants ---
proj3="${tmpdir}/pass_safe"
mkdir -p "${proj3}/src"
cat > "${proj3}/src/lib.rs" <<'EOF'
pub fn get_home() -> String {
    std::env::var("HOME").unwrap_or_default()
}
pub fn get_path() -> String {
    std::env::var("PATH").unwrap_or_else(|_| "/usr/bin".to_string())
}
EOF
assert_ok "unwrap_or variants pass --strict" bash "$GUARD" --strict "$proj3"

# --- PASS: unwrap() inside tests/ directory is ignored ---
proj4="${tmpdir}/pass_test_dir"
mkdir -p "${proj4}/src/tests"
cat > "${proj4}/src/lib.rs" <<'EOF'
pub fn add(a: i32, b: i32) -> i32 { a + b }
EOF
cat > "${proj4}/src/tests/test_add.rs" <<'EOF'
#[test]
fn test_add() {
    let result: Result<i32, ()> = Ok(2);
    assert_eq!(result.unwrap(), 2);
}
EOF
assert_ok "unwrap() in tests/ directory is ignored" bash "$GUARD" --strict "$proj4"

# --- PASS: unwrap() in _test.rs file is ignored ---
proj5="${tmpdir}/pass_test_file"
mkdir -p "${proj5}/src"
cat > "${proj5}/src/math_test.rs" <<'EOF'
fn test_math() {
    let x: Option<i32> = Some(42);
    assert_eq!(x.unwrap(), 42);
}
EOF
assert_ok "unwrap() in _test.rs file is ignored" bash "$GUARD" --strict "$proj5"

# --- PASS: guard-only test file names also ignored by post-edit hook classifier ---
proj5b="${tmpdir}/pass_rust_guard_test_names"
mkdir -p "${proj5b}/src" "${proj5b}/examples" "${proj5b}/benches"
cat > "${proj5b}/src/tests.rs" <<'EOF'
fn fixture() {
    let x: Option<i32> = Some(42);
    let _ = x.expect("fixture");
}
EOF
cat > "${proj5b}/src/test_helpers.rs" <<'EOF'
fn helper() {
    let x: Option<i32> = Some(42);
    let _ = x.unwrap();
}
EOF
cat > "${proj5b}/examples/demo.rs" <<'EOF'
fn main() {
    let x: Option<i32> = Some(42);
    println!("{}", x.unwrap());
}
EOF
cat > "${proj5b}/benches/bench.rs" <<'EOF'
fn bench() {
    let x: Option<i32> = Some(42);
    let _ = x.expect("bench");
}
EOF
assert_ok "tests.rs/test_helpers/examples/benches are ignored" bash "$GUARD" --strict "$proj5b"

# --- PASS: *_tests.rs is ignored by authoritative runtime and shell fallback ---
proj5c="${tmpdir}/pass_tests_suffix"
mkdir -p "${proj5c}/src/nested"
cat > "${proj5c}/src/nested/parser_tests.rs" <<'EOF'
fn parser_fixture() {
    let x: Option<i32> = Some(42);
    let _ = x.expect("fixture");
}
EOF
assert_ok "*_tests.rs is ignored by runtime classifier" \
  run_guard_with_runtime "$runtime_wrapper" --strict "$proj5c"
assert_ok "*_tests.rs is ignored by shell fallback" \
  run_guard_with_runtime "$failing_runtime" --strict "$proj5c"

# --- FAIL: similar production names stay visible while *_tests.rs stays ignored ---
proj5d="${tmpdir}/tests_suffix_boundaries"
mkdir -p "${proj5d}/src"
for name in contest latest tests_support; do
  cat > "${proj5d}/src/${name}.rs" <<EOF
fn ${name}() { let _ = Some(1).unwrap(); }
EOF
done
cat > "${proj5d}/src/foo_tests.rs" <<'EOF'
fn fixture() { let _ = Some(1).unwrap(); }
EOF
for runtime in "$runtime_wrapper" "$failing_runtime"; do
  label="runtime classifier"
  [[ "$runtime" == "$failing_runtime" ]] && label="shell fallback"
  assert_fail "similar production names fail with ${label}" \
    run_guard_with_runtime "$runtime" --strict "$proj5d"
  for name in contest latest tests_support; do
    assert_output_contains "${name}.rs remains visible with ${label}" "${name}.rs" \
      run_guard_with_runtime "$runtime" --strict "$proj5d"
  done
  assert_output_not_contains "foo_tests.rs stays ignored with ${label}" "foo_tests.rs" \
    run_guard_with_runtime "$runtime" --strict "$proj5d"
done

# --- STAGED: production finding remains while *_tests.rs is excluded ---
proj5e="${tmpdir}/staged_tests_suffix"
mkdir -p "${proj5e}/src"
git -C "$proj5e" init -q
git -C "$proj5e" config user.email "vibeguard-tests@example.invalid"
git -C "$proj5e" config user.name "VibeGuard Tests"
cat > "${proj5e}/src/foo.rs" <<'EOF'
fn production() { let _ = Some(1).unwrap(); }
EOF
cat > "${proj5e}/src/foo_tests.rs" <<'EOF'
fn fixture() { let _ = Some(1).unwrap(); }
EOF
git -C "$proj5e" add src/foo.rs src/foo_tests.rs
staged_files="${proj5e}/staged-files"
printf '%s\n' "src/foo.rs" "src/foo_tests.rs" > "$staged_files"
run_staged_guard() {
  (
    cd "$proj5e"
    env \
      VG_TEST_RUNTIME_MANIFEST="${REPO_DIR}/vibeguard-runtime/Cargo.toml" \
      VIBEGUARD_RUNTIME="$runtime_wrapper" \
      VIBEGUARD_STAGED_FILES="$staged_files" \
      bash "$GUARD" --strict "$proj5e"
  )
}
assert_fail "staged production unwrap remains visible" run_staged_guard
assert_output_contains "staged output contains foo.rs" "src/foo.rs" run_staged_guard
assert_output_not_contains "staged output excludes foo_tests.rs" "foo_tests.rs" run_staged_guard

# --- PASS: empty project (no .rs files) ---
proj6="${tmpdir}/pass_empty"
mkdir -p "${proj6}/src"
assert_ok "empty project passes" bash "$GUARD" --strict "$proj6"

# --- PASS: non-strict mode does not exit 1 even with violations ---
proj7="${tmpdir}/nonstrict"
mkdir -p "${proj7}/src"
cat > "${proj7}/src/main.rs" <<'EOF'
fn main() { let x = Some(1).unwrap(); }
EOF
assert_ok "unwrap() without --strict exits 0" bash "$GUARD" "$proj7"

echo
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' "$TOTAL" "$PASS" "$FAIL"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0

#!/usr/bin/env bash
# Unit tests for guards/rust/check_duplicate_types.sh (RS-05)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="${REPO_DIR}/guards/rust/check_duplicate_types.sh"

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

printf '\n=== check_duplicate_types (RS-05) ===\n'

# --- FAIL: same pub struct name in two files ---
proj="${tmpdir}/fail_dup_struct"
mkdir -p "${proj}/src/server" "${proj}/src/desktop"
cat > "${proj}/src/server/config.rs" <<'EOF'
pub struct AppConfig {
    pub host: String,
}
EOF
cat > "${proj}/src/desktop/config.rs" <<'EOF'
pub struct AppConfig {
    pub window_size: u32,
}
EOF
assert_fail "duplicate pub struct fails --strict" bash "$GUARD" --strict "$proj"
assert_output_contains "output contains RS-05 tag" "[RS-05]" bash "$GUARD" --strict "$proj"
assert_output_contains "output names the duplicate type" "AppConfig" bash "$GUARD" --strict "$proj"

# --- FAIL: same pub enum name in two files ---
proj2="${tmpdir}/fail_dup_enum"
mkdir -p "${proj2}/src/a" "${proj2}/src/b"
cat > "${proj2}/src/a/status.rs" <<'EOF'
pub enum Status { Active, Inactive }
EOF
cat > "${proj2}/src/b/status.rs" <<'EOF'
pub enum Status { Running, Stopped }
EOF
assert_fail "duplicate pub enum fails --strict" bash "$GUARD" --strict "$proj2"

# --- PASS: unique type names across files ---
proj3="${tmpdir}/pass_unique"
mkdir -p "${proj3}/src/server" "${proj3}/src/client"
cat > "${proj3}/src/server/types.rs" <<'EOF'
pub struct ServerConfig { pub port: u16 }
pub enum ServerStatus { Running, Stopped }
EOF
cat > "${proj3}/src/client/types.rs" <<'EOF'
pub struct ClientConfig { pub host: String }
pub enum ClientStatus { Connected, Disconnected }
EOF
assert_ok "unique type names pass --strict" bash "$GUARD" --strict "$proj3"

# --- PASS: same name but in tests/ is excluded ---
proj4="${tmpdir}/pass_test_excluded"
mkdir -p "${proj4}/src" "${proj4}/src/tests"
cat > "${proj4}/src/lib.rs" <<'EOF'
pub struct Foo { pub x: i32 }
EOF
cat > "${proj4}/src/tests/helpers.rs" <<'EOF'
pub struct Foo { pub y: String }
EOF
assert_ok "duplicate in tests/ is excluded" bash "$GUARD" --strict "$proj4"

# --- PASS: allowlist suppresses false positives ---
proj5="${tmpdir}/pass_allowlist"
mkdir -p "${proj5}/src/a" "${proj5}/src/b"
cat > "${proj5}/src/a/mod.rs" <<'EOF'
pub struct SharedError { pub msg: String }
EOF
cat > "${proj5}/src/b/mod.rs" <<'EOF'
pub struct SharedError { pub code: u32 }
EOF
echo "SharedError" > "${proj5}/.vibeguard-duplicate-types-allowlist"
assert_ok "allowlisted type is not flagged" bash "$GUARD" --strict "$proj5"

# --- PASS: single definition of a type ---
proj6="${tmpdir}/pass_single"
mkdir -p "${proj6}/src"
cat > "${proj6}/src/types.rs" <<'EOF'
pub struct Task { pub id: u64, pub name: String }
pub enum Priority { Low, Medium, High }
EOF
assert_ok "single definition passes" bash "$GUARD" --strict "$proj6"

# --- ERROR: unreadable/invalid allowlist data must not disable detection silently ---
proj7="${tmpdir}/fail_invalid_allowlist"
mkdir -p "${proj7}/src"
printf 'pub struct Item;\n' > "${proj7}/src/item.rs"
printf '\377' > "${proj7}/.vibeguard-duplicate-types-allowlist"
assert_output_contains "invalid UTF-8 allowlist fails visibly" "cannot read" \
  bash "$GUARD" --strict "$proj7"

# --- BASELINE: historical duplicate debt is quiet until a definition changes ---
proj8="${tmpdir}/baseline_duplicate_debt"
mkdir -p "${proj8}/src/a" "${proj8}/src/b"
git -C "$proj8" init -q
git -C "$proj8" config user.email "vibeguard-tests@example.invalid"
git -C "$proj8" config user.name "VibeGuard Tests"
printf 'pub struct ExistingDuplicate;\n' > "${proj8}/src/a/types.rs"
printf 'pub struct ExistingDuplicate;\n' > "${proj8}/src/b/types.rs"
git -C "$proj8" add src/a/types.rs src/b/types.rs
git -C "$proj8" commit -q -m initial
baseline8="$(git -C "$proj8" rev-parse HEAD)"
printf 'pub struct Unrelated;\n' > "${proj8}/src/unrelated.rs"
git -C "$proj8" add src/unrelated.rs
git -C "$proj8" commit -q -m unrelated
assert_ok "baseline ignores pre-existing duplicate types" \
  bash "$GUARD" --strict --baseline "$baseline8" "$proj8"

mkdir -p "${proj8}/src/c"
printf 'pub struct ExistingDuplicate;\n' > "${proj8}/src/c/types.rs"
git -C "$proj8" add src/c/types.rs
git -C "$proj8" commit -q -m new-duplicate
assert_fail "baseline reports a newly added duplicate definition" \
  bash "$GUARD" --strict --baseline "$baseline8" "$proj8"

# --- BASELINE: removing an allowlist entry re-enables unchanged duplicate checks ---
proj9="${tmpdir}/baseline_allowlist_removal"
mkdir -p "${proj9}/src/a" "${proj9}/src/b"
git -C "$proj9" init -q
git -C "$proj9" config user.email "vibeguard-tests@example.invalid"
git -C "$proj9" config user.name "VibeGuard Tests"
printf 'pub struct AllowedDuplicate;\n' > "${proj9}/src/a/types.rs"
printf 'pub struct AllowedDuplicate;\n' > "${proj9}/src/b/types.rs"
printf 'AllowedDuplicate\n' > "${proj9}/.vibeguard-duplicate-types-allowlist"
git -C "$proj9" add .
git -C "$proj9" commit -q -m allowlisted
baseline9="$(git -C "$proj9" rev-parse HEAD)"
: > "${proj9}/.vibeguard-duplicate-types-allowlist"
git -C "$proj9" add .vibeguard-duplicate-types-allowlist
git -C "$proj9" commit -q -m enforce-duplicate
assert_fail "baseline reports duplicates when their allowlist entry is removed" \
  bash "$GUARD" --strict --baseline "$baseline9" "$proj9"

# --- STAGED: current allowlist is read from the index ---
proj10="${tmpdir}/staged_allowlist_removal"
mkdir -p "${proj10}/src/a" "${proj10}/src/b"
git -C "$proj10" init -q
git -C "$proj10" config user.email "vibeguard-tests@example.invalid"
git -C "$proj10" config user.name "VibeGuard Tests"
printf 'pub struct StagedDuplicate;\n' > "${proj10}/src/a/types.rs"
printf 'pub struct StagedDuplicate;\n' > "${proj10}/src/b/types.rs"
printf 'StagedDuplicate\n' > "${proj10}/.vibeguard-duplicate-types-allowlist"
git -C "$proj10" add .
git -C "$proj10" commit -q -m allowlisted
: > "${proj10}/.vibeguard-duplicate-types-allowlist"
git -C "$proj10" add .vibeguard-duplicate-types-allowlist
printf 'StagedDuplicate\n' > "${proj10}/.vibeguard-duplicate-types-allowlist"
staged10="${tmpdir}/staged_allowlist_files.txt"
printf '%s\n' "${proj10}/.vibeguard-duplicate-types-allowlist" > "$staged10"
assert_fail "staged allowlist removal is not hidden by unstaged content" \
  env VIBEGUARD_STAGED_FILES="$staged10" bash "$GUARD" --strict "$proj10"

echo
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' "$TOTAL" "$PASS" "$FAIL"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0

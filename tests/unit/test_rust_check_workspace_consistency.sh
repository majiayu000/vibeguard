#!/usr/bin/env bash
# Unit tests for guards/rust/check_workspace_consistency.sh (RS-06)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="${REPO_DIR}/guards/rust/check_workspace_consistency.sh"

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

printf '\n=== check_workspace_consistency (RS-06) ===\n'

# --- PASS: not a Cargo workspace (no Cargo.toml) exits 0 ---
proj_no_toml="${tmpdir}/pass_no_toml"
mkdir -p "${proj_no_toml}/src"
assert_ok "no Cargo.toml exits 0 gracefully" bash "$GUARD" --strict "$proj_no_toml"

# --- PASS: Cargo.toml without [workspace] section exits 0 ---
proj_no_ws="${tmpdir}/pass_no_workspace"
mkdir -p "${proj_no_ws}/src"
cat > "${proj_no_ws}/Cargo.toml" <<'EOF'
[package]
name = "my-app"
version = "0.1.0"
EOF
assert_ok "single-crate Cargo.toml skips gracefully" bash "$GUARD" --strict "$proj_no_ws"
assert_output_contains "message indicates not a workspace" "Cargo workspace" bash "$GUARD" --strict "$proj_no_ws"

# --- FAIL: two members use different database env vars ---
proj_incon="${tmpdir}/fail_inconsistent"
mkdir -p "${proj_incon}/server/src" "${proj_incon}/desktop/src"
cat > "${proj_incon}/Cargo.toml" <<'EOF'
[workspace] # inline comments are valid TOML
members = ["server", "desktop"]
EOF
cat > "${proj_incon}/server/Cargo.toml" <<'EOF'
[package]
name = "server"
version = "0.1.0"
EOF
cat > "${proj_incon}/server/src/main.rs" <<'EOF'
fn main() {
    let db = std::env::var("SERVER_DB_PATH").unwrap_or_default();
}
EOF
cat > "${proj_incon}/desktop/Cargo.toml" <<'EOF'
[package]
name = "desktop"
version = "0.1.0"
EOF
cat > "${proj_incon}/desktop/src/main.rs" <<'EOF'
fn main() {
    let db = std::env::var("DESKTOP_DB_PATH").unwrap_or_default();
}
EOF
assert_fail "inconsistent DB env vars across members fails --strict" bash "$GUARD" --strict "$proj_incon"
assert_output_contains "output contains RS-06 tag" "[RS-06]" bash "$GUARD" --strict "$proj_incon"

# --- PASS: named database constants are centralized declarations, not use sites ---
proj_dbnames="${tmpdir}/pass_named_db_constants"
mkdir -p "${proj_dbnames}/api/src" "${proj_dbnames}/cli/src"
cat > "${proj_dbnames}/Cargo.toml" <<'EOF'
[workspace]
members = ["api", "cli"]
EOF
cat > "${proj_dbnames}/api/Cargo.toml" <<'EOF'
[package]
name = "api"
version = "0.1.0"
EOF
cat > "${proj_dbnames}/api/src/db.rs" <<'EOF'
const DB_FILE: &str = "server.db";
EOF
cat > "${proj_dbnames}/cli/Cargo.toml" <<'EOF'
[package]
name = "cli"
version = "0.1.0"
EOF
cat > "${proj_dbnames}/cli/src/db.rs" <<'EOF'
const DB_FILE: &str = "data.db";
EOF
assert_ok "different named database constants are excluded" bash "$GUARD" --strict "$proj_dbnames"

# --- FAIL: URL schemes inside database literals are not treated as comments ---
proj_db_urls="${tmpdir}/fail_database_urls"
mkdir -p "${proj_db_urls}/api/src" "${proj_db_urls}/worker/src"
cat > "${proj_db_urls}/Cargo.toml" <<'EOF'
[workspace]
members = ["api", "worker"]
EOF
for member in api worker; do
  printf '[package]\nname = "%s"\nversion = "0.1.0"\n' "$member" > "${proj_db_urls}/${member}/Cargo.toml"
done
cat > "${proj_db_urls}/api/src/main.rs" <<'EOF'
fn main() { let database = "sqlite://server/a.db"; println!("{database}"); }
EOF
cat > "${proj_db_urls}/worker/src/main.rs" <<'EOF'
fn main() { let database = "sqlite://server/b.db"; println!("{database}"); }
EOF
assert_fail "different URL-like database literals fail --strict" \
  bash "$GUARD" --strict "$proj_db_urls"

# --- PASS: workspace with consistent (same) env var and same db filename across members ---
# NOTE: Both members include the same "app.db" literal so the DB_FILE_MEMBERS associative
# array is non-empty; bash 5.3 treats empty declare -A arrays as unbound under set -u.
proj_con="${tmpdir}/pass_consistent"
mkdir -p "${proj_con}/server/src" "${proj_con}/worker/src"
cat > "${proj_con}/Cargo.toml" <<'EOF'
[workspace]
members = ["server", "worker"]
EOF
cat > "${proj_con}/server/Cargo.toml" <<'EOF'
[package]
name = "server"
version = "0.1.0"
EOF
cat > "${proj_con}/server/src/main.rs" <<'EOF'
fn main() {
    let db = std::env::var("APP_DB_PATH").unwrap_or_else(|_| "app.db".to_string());
    println!("{}", db);
}
EOF
cat > "${proj_con}/worker/Cargo.toml" <<'EOF'
[package]
name = "worker"
version = "0.1.0"
EOF
cat > "${proj_con}/worker/src/main.rs" <<'EOF'
fn main() {
    let db = std::env::var("APP_DB_PATH").unwrap_or_else(|_| "app.db".to_string());
    println!("{}", db);
}
EOF
assert_ok "consistent env var and db filename across members passes" bash "$GUARD" --strict "$proj_con"

# --- FAIL: Cargo member globs work when wildcard is not the final character ---
proj_glob="${tmpdir}/fail_member_glob"
mkdir -p "${proj_glob}/crates/api-service/src" "${proj_glob}/crates/worker-service/src"
cat > "${proj_glob}/Cargo.toml" <<'EOF'
[workspace]
members = ["crates/*-service"]
EOF
for member in api-service worker-service; do
  printf '[package]\nname = "%s"\nversion = "0.1.0"\n' "$member" > "${proj_glob}/crates/${member}/Cargo.toml"
done
printf 'fn main() { let _ = std::env::var("API_DB_PATH"); }\n' > "${proj_glob}/crates/api-service/src/main.rs"
printf 'fn main() { let _ = std::env::var("WORKER_DB_PATH"); }\n' > "${proj_glob}/crates/worker-service/src/main.rs"
assert_fail "non-suffix Cargo member wildcard is expanded" bash "$GUARD" --strict "$proj_glob"

# --- FAIL: Cargo member ? wildcard is expanded ---
proj_question="${tmpdir}/fail_member_question_glob"
mkdir -p "${proj_question}/crates/afoo/src" "${proj_question}/crates/bfoo/src"
cat > "${proj_question}/Cargo.toml" <<'EOF'
[workspace]
members = ["crates/?foo"]
EOF
for member in afoo bfoo; do
  printf '[package]\nname = "%s"\nversion = "0.1.0"\n' "$member" > "${proj_question}/crates/${member}/Cargo.toml"
done
printf 'fn main() { let _ = std::env::var("A_DB_PATH"); }\n' > "${proj_question}/crates/afoo/src/main.rs"
printf 'fn main() { let _ = std::env::var("B_DB_PATH"); }\n' > "${proj_question}/crates/bfoo/src/main.rs"
assert_fail "question-mark Cargo member wildcard is expanded" bash "$GUARD" --strict "$proj_question"

# --- ERROR: malformed UTF-8 workspace metadata fails visibly ---
proj_invalid="${tmpdir}/fail_invalid_cargo"
mkdir -p "${proj_invalid}/src"
printf '\377' > "${proj_invalid}/Cargo.toml"
assert_output_contains "invalid UTF-8 Cargo.toml fails visibly" "cannot read" \
  bash "$GUARD" --strict "$proj_invalid"

# --- PASS: workspace discovery and Rust walking do not follow directory symlinks ---
proj_symlink="${tmpdir}/pass_symlink_boundary"
outside_symlink="${tmpdir}/outside_workspace"
mkdir -p "${proj_symlink}/crates/app/src" "${outside_symlink}/src"
cat > "${proj_symlink}/Cargo.toml" <<'EOF'
[workspace]
members = ["crates/*"]
EOF
cat > "${proj_symlink}/crates/app/Cargo.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"
EOF
printf 'fn main() { let _ = std::env::var("APP_DB_PATH"); }\n' > "${proj_symlink}/crates/app/src/main.rs"
cat > "${outside_symlink}/Cargo.toml" <<'EOF'
[package]
name = "outside"
version = "0.1.0"
EOF
printf 'fn escaped() { let _ = std::env::var("ESCAPED_DB_PATH"); }\n' > "${outside_symlink}/src/lib.rs"
if ln -s "$outside_symlink" "${proj_symlink}/crates/escape" 2>/dev/null \
    && ln -s "$outside_symlink/src" "${proj_symlink}/crates/app/src/escape" 2>/dev/null \
    && ln -s "$proj_symlink" "${proj_symlink}/crates/cycle" 2>/dev/null; then
  assert_ok "workspace symlink escapes and cycles are not scanned" bash "$GUARD" --strict "$proj_symlink"
fi

# --- BASELINE: aggregate drift requires a changed contributing input ---
proj_baseline="${tmpdir}/baseline_scope"
mkdir -p "${proj_baseline}/api/src" "${proj_baseline}/worker/src"
git -C "$proj_baseline" init -q
git -C "$proj_baseline" config user.email "vibeguard-tests@example.invalid"
git -C "$proj_baseline" config user.name "VibeGuard Tests"
printf '[workspace]\nmembers = ["api", "worker"]\n' > "${proj_baseline}/Cargo.toml"
for member in api worker; do
  printf '[package]\nname = "%s"\nversion = "0.1.0"\n' "$member" > "${proj_baseline}/${member}/Cargo.toml"
done
printf 'fn main() { let _ = std::env::var("API_DB_PATH"); }\n' > "${proj_baseline}/api/src/main.rs"
printf 'fn main() { let _ = std::env::var("WORKER_DB_PATH"); }\n' > "${proj_baseline}/worker/src/main.rs"
git -C "$proj_baseline" add .
git -C "$proj_baseline" commit -q -m baseline
baseline="$(git -C "$proj_baseline" rev-parse HEAD)"
printf '\npub fn unrelated() {}\n' >> "${proj_baseline}/api/src/main.rs"
git -C "$proj_baseline" add api/src/main.rs
git -C "$proj_baseline" commit -q -m unrelated
assert_ok "baseline ignores pre-existing RS-06 aggregate debt" \
  bash "$GUARD" --strict --baseline "$baseline" "$proj_baseline"
sed -i.bak 's/WORKER_DB_PATH/WORKER_DATABASE_PATH/' "${proj_baseline}/worker/src/main.rs"
rm -f "${proj_baseline}/worker/src/main.rs.bak"
git -C "$proj_baseline" add worker/src/main.rs
git -C "$proj_baseline" commit -q -m contributor
assert_fail "baseline reports a changed database configuration contributor" \
  bash "$GUARD" --strict --baseline "$baseline" "$proj_baseline"

# --- STAGED: aggregate sources are read from the index, not unstaged worktree content ---
proj_staged="${tmpdir}/staged_index_sources"
mkdir -p "${proj_staged}/api/src" "${proj_staged}/worker/src"
git -C "$proj_staged" init -q
git -C "$proj_staged" config user.email "vibeguard-tests@example.invalid"
git -C "$proj_staged" config user.name "VibeGuard Tests"
printf '[workspace]\nmembers = ["api", "worker"]\n' > "${proj_staged}/Cargo.toml"
for member in api worker; do
  printf '[package]\nname = "%s"\nversion = "0.1.0"\n' "$member" > "${proj_staged}/${member}/Cargo.toml"
  printf 'fn main() { let _ = std::env::var("APP_DB_PATH"); }\n' > "${proj_staged}/${member}/src/main.rs"
done
git -C "$proj_staged" add .
git -C "$proj_staged" commit -q -m baseline
printf 'fn main() { let _ = std::env::var("WORKER_DB_PATH"); }\n' > "${proj_staged}/worker/src/main.rs"
git -C "$proj_staged" add worker/src/main.rs
printf 'fn main() { let _ = std::env::var("APP_DB_PATH"); }\n' > "${proj_staged}/worker/src/main.rs"
staged_list="${tmpdir}/staged_workspace_files.txt"
printf '%s\n' "${proj_staged}/worker/src/main.rs" > "$staged_list"
assert_fail "staged RS-06 reads conflicting source from the index" \
  env VIBEGUARD_STAGED_FILES="$staged_list" bash "$GUARD" --strict "$proj_staged"

echo
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' "$TOTAL" "$PASS" "$FAIL"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0

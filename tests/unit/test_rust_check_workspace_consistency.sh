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
[workspace]
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

# --- FAIL: two members use different hardcoded .db filenames ---
proj_dbnames="${tmpdir}/fail_db_names"
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
assert_fail "different hardcoded .db names across members fails --strict" bash "$GUARD" --strict "$proj_dbnames"

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

echo
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' "$TOTAL" "$PASS" "$FAIL"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0

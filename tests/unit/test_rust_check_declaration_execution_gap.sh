#!/usr/bin/env bash
# Unit tests for guards/rust/check_declaration_execution_gap.sh (RS-14)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="${REPO_DIR}/guards/rust/check_declaration_execution_gap.sh"

PASS=0; FAIL=0; SKIP=0; TOTAL=0

green()  { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()    { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
yellow() { printf '\033[33m  SKIP: %s\033[0m\n' "$1"; }

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
  if echo "$out" | grep -qF "$unexpected"; then red "$desc (unexpectedly found: $unexpected)"; FAIL=$((FAIL+1))
  else green "$desc"; PASS=$((PASS+1)); fi
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

printf '\n=== check_declaration_execution_gap (RS-14) ===\n'

# --- FAIL: Config::default() used in production code ---
proj_default="${tmpdir}/fail_config_default"
mkdir -p "${proj_default}/src"
cat > "${proj_default}/src/config.rs" <<'EOF'
pub struct AppConfig {
    pub port: u16,
    pub host: String,
}

impl AppConfig {
    pub fn load(path: &str) -> Result<Self, std::io::Error> {
        Ok(AppConfig { port: 8080, host: "localhost".to_string() })
    }
}

impl Default for AppConfig {
    fn default() -> Self {
        AppConfig { port: 3000, host: "127.0.0.1".to_string() }
    }
}
EOF
cat > "${proj_default}/src/main.rs" <<'EOF'
mod config;
fn main() {
    let cfg = config::AppConfig::default();
    println!("Running on port {}", cfg.port);
}
EOF
assert_fail "Config::default() in production fails --strict" \
  bash "$GUARD" --strict "$proj_default"
assert_output_contains "output contains RS-14 tag" "[RS-14]" \
  bash "$GUARD" --strict "$proj_default"
assert_output_contains "output contains AppConfig::default()" "AppConfig::default()" \
  bash "$GUARD" --strict "$proj_default"

# --- PASS: ServerConfig::default() without load() method is not flagged ---
proj_server="${tmpdir}/pass_server_no_load"
mkdir -p "${proj_server}/src"
cat > "${proj_server}/src/main.rs" <<'EOF'
fn main() {
    let cfg = ServerConfig::default();
    start(cfg);
}
EOF
assert_ok "ServerConfig::default() without load() passes --strict" \
  bash "$GUARD" --strict "$proj_server"

# --- PASS: Config::default() only in test files ---
proj_test_only="${tmpdir}/pass_test_only"
mkdir -p "${proj_test_only}/src/tests"
cat > "${proj_test_only}/src/lib.rs" <<'EOF'
pub fn add(a: i32, b: i32) -> i32 { a + b }
EOF
cat > "${proj_test_only}/src/tests/test_config.rs" <<'EOF'
#[test]
fn test_default() {
    let cfg = AppConfig::default();
    assert_eq!(cfg.port, 3000);
}
EOF
assert_ok "Config::default() only in tests/ passes" \
  bash "$GUARD" --strict "$proj_test_only"

# --- PASS: Config load() is called correctly (no default) ---
proj_loads="${tmpdir}/pass_config_load"
mkdir -p "${proj_loads}/src"
cat > "${proj_loads}/src/config.rs" <<'EOF'
pub struct AppConfig { pub port: u16 }
impl AppConfig {
    pub fn load() -> Result<Self, std::io::Error> {
        Ok(AppConfig { port: 8080 })
    }
}
EOF
cat > "${proj_loads}/src/main.rs" <<'EOF'
mod config;
fn main() {
    let cfg = config::AppConfig::load().expect("config load failed");
    println!("Port: {}", cfg.port);
}
EOF
assert_ok "Config::load() called correctly passes" \
  bash "$GUARD" --strict "$proj_loads"

# --- PASS: non-Config struct uses default() ---
proj_non_config="${tmpdir}/pass_non_config"
mkdir -p "${proj_non_config}/src"
cat > "${proj_non_config}/src/main.rs" <<'EOF'
fn main() {
    let state = AppState::default();
    let opts = Options::default();
}
EOF
assert_ok "Non-Config structs using default() pass" \
  bash "$GUARD" --strict "$proj_non_config"
assert_output_not_contains "No Config violations in output" "AppState::default()" \
  bash "$GUARD" --strict "$proj_non_config"

# --- FAIL: persistence methods on non-Config types must be called at startup ---
proj_store="${tmpdir}/fail_non_config_persistence"
mkdir -p "${proj_store}/src"
cat > "${proj_store}/src/store.rs" <<'EOF'
pub struct StateStore;
impl StateStore {
    pub fn persist(&self) {}
}
EOF
cat > "${proj_store}/src/main.rs" <<'EOF'
mod store;
fn main() {}
EOF
assert_fail "unused persistence method on non-Config type fails" \
  bash "$GUARD" --strict "$proj_store"
assert_output_contains "non-Config persistence finding names the type" "StateStore::persist()" \
  bash "$GUARD" --strict "$proj_store"

# --- PASS: same-named Config types keep their qualified module identities ---
proj_qualified="${tmpdir}/pass_qualified_config_identity"
mkdir -p "${proj_qualified}/src"
cat > "${proj_qualified}/src/config_a.rs" <<'EOF'
pub struct AppConfig;
impl AppConfig { pub fn load() -> Self { Self } }
EOF
cat > "${proj_qualified}/src/config_b.rs" <<'EOF'
pub struct AppConfig;
impl Default for AppConfig { fn default() -> Self { Self } }
EOF
cat > "${proj_qualified}/src/main.rs" <<'EOF'
mod config_a;
mod config_b;
fn main() {
    let _loaded = config_a::AppConfig::load();
    let _defaults = config_b::AppConfig::default();
}
EOF
assert_ok "qualified Config identity avoids cross-module load pollution" \
  bash "$GUARD" --strict "$proj_qualified"

# --- FAIL: super-qualified Config paths resolve from the caller module ---
proj_super="${tmpdir}/fail_super_qualified_config"
mkdir -p "${proj_super}/src/commands"
cat > "${proj_super}/src/commands/config.rs" <<'EOF'
pub struct AppConfig;
impl AppConfig { pub fn load() -> Self { Self } }
EOF
cat > "${proj_super}/src/commands/start.rs" <<'EOF'
pub fn start() {
    let _config = super::config::AppConfig::default();
}
EOF
assert_output_contains "super-qualified Config path detects load bypass" \
  "super::config::AppConfig::default()" bash "$GUARD" --strict "$proj_super"

# --- FAIL: balanced nested generic impl headers still register load() ---
proj_nested_generic="${tmpdir}/fail_nested_generic_impl"
mkdir -p "${proj_nested_generic}/src"
cat > "${proj_nested_generic}/src/config.rs" <<'EOF'
pub struct AppConfig<T>(T);
impl<T: Into<Vec<u8>>> AppConfig<T> {
    pub fn load(value: T) -> Self { Self(value) }
}
impl<T: Default> Default for AppConfig<T> {
    fn default() -> Self { Self(T::default()) }
}
EOF
cat > "${proj_nested_generic}/src/main.rs" <<'EOF'
mod config;
use config::AppConfig;
fn main() { let _config = AppConfig::<Vec<u8>>::default(); }
EOF
assert_fail "nested generic Config impl still protects default()" \
  bash "$GUARD" --strict "$proj_nested_generic"

# --- STAGED: unchanged Config impls participate in the method index ---
proj_staged="${tmpdir}/fail_staged_unchanged_impl"
mkdir -p "${proj_staged}/src"
git -C "$proj_staged" init -q
git -C "$proj_staged" config user.email "vibeguard-tests@example.invalid"
git -C "$proj_staged" config user.name "VibeGuard Tests"
cat > "${proj_staged}/src/config.rs" <<'EOF'
pub struct AppConfig;
impl AppConfig { pub fn load() -> Self { Self } }
EOF
cat > "${proj_staged}/src/main.rs" <<'EOF'
mod config;
fn main() { let _config = config::AppConfig::load(); }
EOF
git -C "$proj_staged" add src/config.rs src/main.rs
git -C "$proj_staged" commit -q -m initial
cat > "${proj_staged}/src/main.rs" <<'EOF'
mod config;
fn main() {
    let _loaded = config::AppConfig::load();
    let _defaults = config::AppConfig::default();
}
EOF
git -C "$proj_staged" add src/main.rs
staged_list="${proj_staged}/staged-files"
printf '%s\n' "${proj_staged}/src/main.rs" > "$staged_list"
assert_fail "staged default() sees unchanged load() implementation" \
  env VIBEGUARD_STAGED_FILES="$staged_list" bash "$GUARD" --strict "$proj_staged"

# --- PASS: persistence declarations honor the documented suppression directive ---
proj_suppressed="${tmpdir}/pass_suppressed_persistence_declaration"
mkdir -p "${proj_suppressed}/src"
cat > "${proj_suppressed}/src/config.rs" <<'EOF'
pub struct AppConfig;
impl AppConfig {
    // vibeguard-disable-next-line RS-14 -- intentionally invoked outside startup
    pub fn save(&self) {}
}
EOF
assert_ok "suppressed persistence declaration passes" bash "$GUARD" --strict "$proj_suppressed"

# --- BASELINE: deleting the only startup call rechecks an unchanged declaration ---
proj_deleted_call="${tmpdir}/fail_deleted_startup_call"
mkdir -p "${proj_deleted_call}/src"
git -C "$proj_deleted_call" init -q
git -C "$proj_deleted_call" config user.email "vibeguard-tests@example.invalid"
git -C "$proj_deleted_call" config user.name "VibeGuard Tests"
cat > "${proj_deleted_call}/src/config.rs" <<'EOF'
pub struct AppConfig;
impl AppConfig { pub fn load() -> Self { Self } }
EOF
cat > "${proj_deleted_call}/src/main.rs" <<'EOF'
mod config;
fn main() { let _config = config::AppConfig::load(); }
EOF
git -C "$proj_deleted_call" add src/config.rs src/main.rs
git -C "$proj_deleted_call" commit -q -m initial
deleted_call_baseline="$(git -C "$proj_deleted_call" rev-parse HEAD)"
cat > "${proj_deleted_call}/src/main.rs" <<'EOF'
mod config;
fn main() {}
EOF
git -C "$proj_deleted_call" add src/main.rs
git -C "$proj_deleted_call" commit -q -m remove-load
assert_fail "deleted startup persistence call fails baseline scan" \
  bash "$GUARD" --strict --baseline "$deleted_call_baseline" "$proj_deleted_call"

# --- PASS: empty project ---
proj_empty="${tmpdir}/pass_empty"
mkdir -p "${proj_empty}/src"
assert_ok "empty project passes" bash "$GUARD" --strict "$proj_empty"

# --- PASS: violations without --strict exit 0 ---
proj_nonstrict="${tmpdir}/pass_nonstrict"
mkdir -p "${proj_nonstrict}/src"
cat > "${proj_nonstrict}/src/main.rs" <<'EOF'
fn main() {
    let cfg = ServerConfig::default();
}
EOF
assert_ok "violations without --strict exits 0" bash "$GUARD" "$proj_nonstrict"

echo
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m  Skip: \033[33m%d\033[0m\n' \
  "$TOTAL" "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0

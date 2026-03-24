#!/usr/bin/env bash
# Unit tests for guards/rust/check_declaration_execution_gap.sh (RS-14)
#
# NOTE: This guard requires ast-grep. Tests are skipped if ast-grep is unavailable.
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

# Skip gracefully if ast-grep is not available
if ! command -v ast-grep >/dev/null 2>&1; then
  SKIP=$((SKIP+1))
  yellow "ast-grep not available — skipping RS-14 tests"
  echo
  printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m  Skip: \033[33m%d\033[0m\n' \
    "$TOTAL" "$PASS" "$FAIL" "$SKIP"
  exit 0
fi

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

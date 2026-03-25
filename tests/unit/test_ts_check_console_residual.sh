#!/usr/bin/env bash
# Unit tests for guards/typescript/check_console_residual.sh (TS-03)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="${REPO_DIR}/guards/typescript/check_console_residual.sh"

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

printf '\n=== check_console_residual (TS-03) ===\n'

# --- FAIL: console.log in production code ---
proj_log="${tmpdir}/fail_console_log"
mkdir -p "${proj_log}/src"
cat > "${proj_log}/src/handler.ts" <<'EOF'
export function processRequest(input: string): string {
  console.log("processing:", input);
  return input.toUpperCase();
}
EOF
assert_fail "console.log fails --strict" bash "$GUARD" --strict "$proj_log"
assert_output_contains "output contains TS-03 tag" "[TS-03]" bash "$GUARD" --strict "$proj_log"

# --- FAIL: console.warn ---
proj_warn="${tmpdir}/fail_console_warn"
mkdir -p "${proj_warn}/src"
cat > "${proj_warn}/src/validator.ts" <<'EOF'
export function validate(val: number): boolean {
  if (val < 0) {
    console.warn("negative value detected:", val);
    return false;
  }
  return true;
}
EOF
assert_fail "console.warn fails --strict" bash "$GUARD" --strict "$proj_warn"

# --- FAIL: console.error in non-MCP file ---
proj_err="${tmpdir}/fail_console_error"
mkdir -p "${proj_err}/src"
cat > "${proj_err}/src/fetcher.ts" <<'EOF'
export async function fetchData(url: string): Promise<string> {
  try {
    const resp = await fetch(url);
    return await resp.text();
  } catch (e) {
    console.error("fetch failed", e);
    return "";
  }
}
EOF
assert_fail "console.error fails --strict in non-MCP file" bash "$GUARD" --strict "$proj_err"

# --- PASS: no console calls ---
proj_clean="${tmpdir}/pass_clean"
mkdir -p "${proj_clean}/src"
cat > "${proj_clean}/src/math.ts" <<'EOF'
export function add(a: number, b: number): number {
  return a + b;
}

export function multiply(a: number, b: number): number {
  return a * b;
}
EOF
assert_ok "no console calls passes" bash "$GUARD" --strict "$proj_clean"

# --- PASS: console calls in logger file are excluded ---
proj_logger="${tmpdir}/pass_logger"
mkdir -p "${proj_logger}/src"
cat > "${proj_logger}/src/logger.ts" <<'EOF'
export function log(msg: string): void {
  console.log(`[INFO] ${msg}`);
}
export function warn(msg: string): void {
  console.warn(`[WARN] ${msg}`);
}
EOF
assert_ok "console in logger.ts is excluded" bash "$GUARD" --strict "$proj_logger"

# --- FAIL: business file under parent dir whose name contains 'logger' must still be detected ---
# Regression for: LOGGER_PATTERN was matched against full absolute path, causing files under
# any ancestor dir named "logger" / "logging" to be silently skipped (TS-03 漏检).
proj_logger_parent="${tmpdir}/logging_service"
mkdir -p "${proj_logger_parent}/src"
cat > "${proj_logger_parent}/src/handler.ts" <<'EOF'
export function processRequest(input: string): string {
  console.log("processing:", input);
  return input.toUpperCase();
}
EOF
assert_fail "console.log in file under 'logging' parent dir fails --strict" bash "$GUARD" --strict "$proj_logger_parent"
assert_output_contains "path-contamination: output contains TS-03 tag" "[TS-03]" bash "$GUARD" --strict "$proj_logger_parent"

# --- PASS: MCP entry point with console.error is excluded ---
proj_mcp="${tmpdir}/pass_mcp"
mkdir -p "${proj_mcp}/src"
cat > "${proj_mcp}/src/index.ts" <<'EOF'
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";

const server = new Server({ name: "my-server", version: "1.0.0" }, { capabilities: {} });
const transport = new StdioServerTransport();
server.connect(transport).catch((err) => {
  console.error("Server error:", err);
  process.exit(1);
});
EOF
assert_ok "MCP entry point with console.error is excluded" bash "$GUARD" --strict "$proj_mcp"

# --- PASS: test files are excluded ---
proj_test="${tmpdir}/pass_test"
mkdir -p "${proj_test}/src"
cat > "${proj_test}/src/handler.test.ts" <<'EOF'
describe("handler", () => {
  it("logs output", () => {
    console.log("test debug");
    expect(true).toBe(true);
  });
});
EOF
assert_ok "console.log in .test.ts is excluded" bash "$GUARD" --strict "$proj_test"

# --- PASS: console in comment is not flagged ---
proj_commented="${tmpdir}/pass_commented"
mkdir -p "${proj_commented}/src"
cat > "${proj_commented}/src/service.ts" <<'EOF'
// Remove console.log before shipping
export function doWork(): void {
  // was: console.log("debug")
  const result = 42;
}
EOF
assert_ok "console.log only in comments passes" bash "$GUARD" --strict "$proj_commented"

echo
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' "$TOTAL" "$PASS" "$FAIL"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0

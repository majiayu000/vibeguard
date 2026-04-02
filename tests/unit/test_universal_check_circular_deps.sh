#!/usr/bin/env bash
# Unit tests for guards/universal/check_circular_deps.py
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="${REPO_DIR}/guards/universal/check_circular_deps.py"

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

printf '\n=== check_circular_deps (Python) ===\n'

if ! command -v python3 >/dev/null 2>&1; then
  printf '\033[33m  SKIP: python3 not available\033[0m\n'
  exit 0
fi

# --- FAIL: direct circular dependency A → B → A (TypeScript) ---
proj_cycle="${tmpdir}/fail_ts_cycle"
mkdir -p "${proj_cycle}/src/moduleA" "${proj_cycle}/src/moduleB"
cat > "${proj_cycle}/src/moduleA/index.ts" <<'EOF'
import { doB } from "../moduleB/index";
export function doA(): void { doB(); }
EOF
cat > "${proj_cycle}/src/moduleB/index.ts" <<'EOF'
import { doA } from "../moduleA/index";
export function doB(): void { doA(); }
EOF
assert_fail "circular TS dep A→B→A fails" python3 "$GUARD" "$proj_cycle"
assert_output_contains "output mentions cycle count" "cyclic dependencies" python3 "$GUARD" "$proj_cycle"

# --- FAIL: circular Python dependency ---
proj_py_cycle="${tmpdir}/fail_py_cycle"
mkdir -p "${proj_py_cycle}/src/alpha" "${proj_py_cycle}/src/beta"
cat > "${proj_py_cycle}/src/alpha/__init__.py" <<'EOF'
from beta import helper
EOF
cat > "${proj_py_cycle}/src/beta/__init__.py" <<'EOF'
from alpha import process
EOF
assert_fail "circular Python dep fails" python3 "$GUARD" "$proj_py_cycle"

# --- PASS: no circular dependencies (linear chain) ---
proj_linear="${tmpdir}/pass_linear"
mkdir -p "${proj_linear}/src/core" "${proj_linear}/src/service" "${proj_linear}/src/api"
cat > "${proj_linear}/src/core/index.ts" <<'EOF'
export function coreUtil(): string { return "core"; }
EOF
cat > "${proj_linear}/src/service/index.ts" <<'EOF'
import { coreUtil } from "../core/index";
export function serviceLogic(): string { return coreUtil() + "-service"; }
EOF
cat > "${proj_linear}/src/api/index.ts" <<'EOF'
import { serviceLogic } from "../service/index";
export function apiHandler(): string { return serviceLogic() + "-api"; }
EOF
assert_ok "linear dependency chain passes" python3 "$GUARD" "$proj_linear"

# --- PASS: completely isolated modules (no imports) ---
proj_isolated="${tmpdir}/pass_isolated"
mkdir -p "${proj_isolated}/src/utils" "${proj_isolated}/src/models"
cat > "${proj_isolated}/src/utils/math.ts" <<'EOF'
export const PI = 3.14159;
export function square(x: number): number { return x * x; }
EOF
cat > "${proj_isolated}/src/models/user.ts" <<'EOF'
export interface User { id: number; name: string; }
EOF
assert_ok "isolated modules with no cross-imports passes" python3 "$GUARD" "$proj_isolated"

# --- PASS: empty directory ---
proj_empty="${tmpdir}/pass_empty"
mkdir -p "${proj_empty}"
assert_ok "empty directory exits 0" python3 "$GUARD" "$proj_empty"

# --- PASS: 3-node cycle is detected as failure ---
proj_three="${tmpdir}/fail_three_cycle"
mkdir -p "${proj_three}/src/a" "${proj_three}/src/b" "${proj_three}/src/c"
cat > "${proj_three}/src/a/index.ts" <<'EOF'
import { fromB } from "../b/index";
export function fromA() { return fromB(); }
EOF
cat > "${proj_three}/src/b/index.ts" <<'EOF'
import { fromC } from "../c/index";
export function fromB() { return fromC(); }
EOF
cat > "${proj_three}/src/c/index.ts" <<'EOF'
import { fromA } from "../a/index";
export function fromC() { return fromA(); }
EOF
assert_fail "3-node circular dep A→B→C→A fails" python3 "$GUARD" "$proj_three"

echo
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' "$TOTAL" "$PASS" "$FAIL"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0

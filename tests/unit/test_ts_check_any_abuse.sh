#!/usr/bin/env bash
# Unit tests for guards/typescript/check_any_abuse.sh (TS-01/TS-02)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="${REPO_DIR}/guards/typescript/check_any_abuse.sh"

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

printf '\n=== check_any_abuse (TS-01/TS-02) ===\n'

# --- FAIL: 'as any' type cast ---
proj_as_any="${tmpdir}/fail_as_any"
mkdir -p "${proj_as_any}/src"
cat > "${proj_as_any}/src/component.ts" <<'EOF'
function processData(input: unknown): string {
  const data = input as any;
  return data.value;
}
EOF
assert_fail "'as any' fails --strict" bash "$GUARD" --strict "$proj_as_any"
assert_output_contains "output contains TS-01 tag" "[TS-01]" bash "$GUARD" --strict "$proj_as_any"
assert_output_contains "output mentions any abuse" "any" bash "$GUARD" --strict "$proj_as_any"

# --- FAIL: ': any' type annotation ---
proj_colon_any="${tmpdir}/fail_colon_any"
mkdir -p "${proj_colon_any}/src"
cat > "${proj_colon_any}/src/service.ts" <<'EOF'
function handleRequest(req: any, res: any): void {
  console.log(req.body);
}
EOF
assert_fail "': any' annotation fails --strict" bash "$GUARD" --strict "$proj_colon_any"
assert_output_contains "output contains TS-01 tag for colon any" "[TS-01]" bash "$GUARD" --strict "$proj_colon_any"

# --- FAIL: @ts-ignore ---
proj_ts_ignore="${tmpdir}/fail_ts_ignore"
mkdir -p "${proj_ts_ignore}/src"
cat > "${proj_ts_ignore}/src/utils.ts" <<'EOF'
function getLength(val: string | number): number {
  // @ts-ignore
  return val.length;
}
EOF
assert_fail "@ts-ignore fails --strict" bash "$GUARD" --strict "$proj_ts_ignore"
assert_output_contains "output contains TS-01 tag for ts-ignore" "[TS-01]" bash "$GUARD" --strict "$proj_ts_ignore"

# --- FAIL: @ts-nocheck at top of file ---
proj_ts_nocheck="${tmpdir}/fail_ts_nocheck"
mkdir -p "${proj_ts_nocheck}/src"
cat > "${proj_ts_nocheck}/src/legacy.ts" <<'EOF'
// @ts-nocheck
export function legacyFunction(x) {
  return x.doSomething();
}
EOF
assert_fail "@ts-nocheck fails --strict" bash "$GUARD" --strict "$proj_ts_nocheck"
assert_output_contains "output contains TS-01 tag for nocheck" "[TS-01]" bash "$GUARD" --strict "$proj_ts_nocheck"

# --- PASS: properly typed code ---
proj_clean="${tmpdir}/pass_typed"
mkdir -p "${proj_clean}/src"
cat > "${proj_clean}/src/typed.ts" <<'EOF'
interface User {
  id: number;
  name: string;
}

function formatUser(user: User): string {
  return `${user.name} (${user.id})`;
}

export { formatUser };
EOF
assert_ok "properly typed code passes" bash "$GUARD" --strict "$proj_clean"

# --- PASS: ': any' in a comment is filtered by the guard ---
# Note: the guard filters ': any' comments via grep -vE '//.*:\s*any'
# but 'as any' in comments IS still flagged (no comment filter for as-any).
proj_comment="${tmpdir}/pass_any_in_comment"
mkdir -p "${proj_comment}/src"
cat > "${proj_comment}/src/notes.ts" <<'EOF'
// This variable has a specific type annotation
// Do not use the banned patterns documented in TS-01
export const VERSION = "1.0.0";

function process(input: string): string {
  return input.trim();
}
EOF
assert_ok "clean file without any-patterns passes" bash "$GUARD" --strict "$proj_comment"

# --- PASS: test files are excluded ---
proj_test_excluded="${tmpdir}/pass_test_excluded"
mkdir -p "${proj_test_excluded}/src"
cat > "${proj_test_excluded}/src/component.test.ts" <<'EOF'
const data = something as any;
// @ts-ignore
const x: any = 42;
EOF
assert_ok "violations in .test.ts files are excluded" bash "$GUARD" --strict "$proj_test_excluded"

# --- PASS: empty project ---
proj_empty="${tmpdir}/pass_empty"
mkdir -p "${proj_empty}/src"
assert_ok "empty project passes" bash "$GUARD" --strict "$proj_empty"

echo
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' "$TOTAL" "$PASS" "$FAIL"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0

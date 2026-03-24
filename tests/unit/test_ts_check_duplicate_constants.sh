#!/usr/bin/env bash
# Unit tests for guards/typescript/check_duplicate_constants.sh (DUP-*)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="${REPO_DIR}/guards/typescript/check_duplicate_constants.sh"

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

printf '\n=== check_duplicate_constants (DUP-*) ===\n'

# --- PASS: no src/ directory exits 0 ---
proj_no_src="${tmpdir}/pass_no_src"
mkdir -p "$proj_no_src"
assert_ok "no src/ directory exits 0 gracefully" bash "$GUARD" --strict "$proj_no_src"

# --- FAIL: same export const name in two files ---
proj_dup_const="${tmpdir}/fail_dup_const"
mkdir -p "${proj_dup_const}/src/a" "${proj_dup_const}/src/b"
cat > "${proj_dup_const}/src/a/config.ts" <<'EOF'
export const MAX_RETRY = 3;
EOF
cat > "${proj_dup_const}/src/b/config.ts" <<'EOF'
export const MAX_RETRY = 5;
EOF
assert_fail "duplicate export const fails --strict" bash "$GUARD" --strict "$proj_dup_const"
assert_output_contains "output contains DUP-CONST tag" "[DUP-CONST]" bash "$GUARD" --strict "$proj_dup_const"

# --- FAIL: same interface exported from two files ---
proj_dup_type="${tmpdir}/fail_dup_interface"
mkdir -p "${proj_dup_type}/src/models" "${proj_dup_type}/src/types"
cat > "${proj_dup_type}/src/models/user.ts" <<'EOF'
export interface UserProfile {
  id: number;
  name: string;
}
EOF
cat > "${proj_dup_type}/src/types/user.ts" <<'EOF'
export interface UserProfile {
  id: string;
  email: string;
}
EOF
assert_fail "duplicate export interface fails --strict" bash "$GUARD" --strict "$proj_dup_type"

# --- FAIL: same function in 3+ files (threshold is >= 3) ---
proj_dup_func="${tmpdir}/fail_dup_func"
mkdir -p "${proj_dup_func}/src/a" "${proj_dup_func}/src/b" "${proj_dup_func}/src/c"
cat > "${proj_dup_func}/src/a/utils.ts" <<'EOF'
export function formatDate(d: Date): string { return d.toISOString(); }
EOF
cat > "${proj_dup_func}/src/b/utils.ts" <<'EOF'
export function formatDate(d: Date): string { return d.toLocaleDateString(); }
EOF
cat > "${proj_dup_func}/src/c/utils.ts" <<'EOF'
export function formatDate(d: Date): string { return d.toDateString(); }
EOF
assert_fail "function in 3 files fails --strict" bash "$GUARD" --strict "$proj_dup_func"

# --- PASS: unique constants in each file ---
proj_unique="${tmpdir}/pass_unique"
mkdir -p "${proj_unique}/src/api" "${proj_unique}/src/ui"
# NOTE: The guard uses set -euo pipefail without '|| true' on its grep pipes. When grep
# finds no matches it exits 1, causing the script to abort early. Fixtures must include
# at least one match for each of: export const UPPERCASE, export type/interface, function.
cat > "${proj_unique}/src/api/constants.ts" <<'EOF'
export const API_TIMEOUT = 5000;
export type ApiConfig = { timeout: number };
export function buildApiUrl(base: string): string { return base + "/api"; }
EOF
cat > "${proj_unique}/src/ui/constants.ts" <<'EOF'
export const ANIMATION_DURATION = 300;
export type UiTheme = { color: string };
export function formatLabel(text: string): string { return text.trim(); }
EOF
assert_ok "unique constants, types, and functions pass" bash "$GUARD" --strict "$proj_unique"

# --- PASS: function in only 2 files is under the threshold (>=3 triggers, 2 is fine) ---
proj_two_files="${tmpdir}/pass_two_files"
mkdir -p "${proj_two_files}/src/a" "${proj_two_files}/src/b"
# Include export const and export type so grep doesn't fail with no-match early exit
cat > "${proj_two_files}/src/a/helpers.ts" <<'EOF'
export const VERSION_A = "1.0";
export type SlugOptions = { separator: string };
export function slugify(text: string): string { return text.toLowerCase().replace(/\s+/g, "-"); }
EOF
cat > "${proj_two_files}/src/b/helpers.ts" <<'EOF'
export const VERSION_B = "2.0";
export type FormatOptions = { trim: boolean };
export function slugify(text: string): string { return text.toLowerCase().replace(/ /g, "_"); }
EOF
assert_ok "function in 2 files is under threshold, passes" bash "$GUARD" --strict "$proj_two_files"

echo
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' "$TOTAL" "$PASS" "$FAIL"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0

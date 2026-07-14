#!/usr/bin/env bash
# Unit tests for guards/universal/check_code_slop.sh (SLOP)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="${REPO_DIR}/guards/universal/check_code_slop.sh"

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
  if printf '%s\n' "$out" | grep -qF "$unexpected"; then
    red "$desc (unexpected: $unexpected)"; FAIL=$((FAIL+1))
  else
    green "$desc"; PASS=$((PASS+1))
  fi
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

printf '\n=== check_code_slop (SLOP) ===\n'

# --- FAIL: empty catch block in TypeScript ---
proj_empty_catch="${tmpdir}/fail_empty_catch"
mkdir -p "${proj_empty_catch}"
cat > "${proj_empty_catch}/handler.ts" <<'EOF'
async function fetchData(url: string): Promise<string> {
  try {
    const resp = await fetch(url);
    return await resp.text();
  } catch (e) {}
}
EOF
assert_fail "empty catch block in TS fails" bash "$GUARD" "$proj_empty_catch"
assert_output_contains "output mentions empty exception handling" "empty exception handling block" bash "$GUARD" "$proj_empty_catch"

# --- FAIL: empty except in Python ---
proj_empty_except="${tmpdir}/fail_empty_except"
mkdir -p "${proj_empty_except}"
cat > "${proj_empty_except}/service.py" <<'EOF'
def process(data):
    try:
        return int(data)
    except:
        pass
EOF
assert_fail "empty except:pass in Python fails" bash "$GUARD" "$proj_empty_except"

# --- FAIL: debug code left in production (console.log) ---
proj_debug="${tmpdir}/fail_debug_code"
mkdir -p "${proj_debug}"
cat > "${proj_debug}/app.ts" <<'EOF'
export function processOrder(order: any): void {
  console.log(order);
  submitOrder(order);
}
function submitOrder(_: any): void {}
EOF
assert_fail "leftover console.log fails" bash "$GUARD" "$proj_debug"
assert_output_contains "output mentions debug code" "Legacy debug code" bash "$GUARD" "$proj_debug"

# --- FAIL: print() debug in Python ---
proj_print="${tmpdir}/fail_print"
mkdir -p "${proj_print}"
cat > "${proj_print}/util.py" <<'EOF'
def transform(data):
    print(data)
    return data.upper()
EOF
assert_fail "print() debug in Python fails" bash "$GUARD" "$proj_print"

# --- FAIL: file exceeding 300 lines ---
proj_long="${tmpdir}/fail_long_file"
mkdir -p "${proj_long}"
# Generate a .py file with > 300 lines
python3 -c "
lines = ['def fn_{}(): pass'.format(i) for i in range(310)]
print('\n'.join(lines))
" > "${proj_long}/big_module.py"
assert_fail "file with >300 lines fails" bash "$GUARD" "$proj_long"

# --- PASS: clean project with short files and no debug code ---
proj_clean="${tmpdir}/pass_clean"
mkdir -p "${proj_clean}"
cat > "${proj_clean}/utils.py" <<'EOF'
def add(a: int, b: int) -> int:
    return a + b

def multiply(a: int, b: int) -> int:
    return a * b
EOF
cat > "${proj_clean}/config.ts" <<'EOF'
export const DEFAULT_TIMEOUT = 5000;
export const MAX_RETRIES = 3;
EOF
assert_ok "clean project passes" bash "$GUARD" "$proj_clean"

# --- PASS: empty directory ---
proj_empty="${tmpdir}/pass_empty"
mkdir -p "${proj_empty}"
assert_ok "empty directory passes" bash "$GUARD" "$proj_empty"

# --- PASS: console.log present but all occurrences have // keep marker ---
proj_kept="${tmpdir}/pass_kept_debug"
mkdir -p "${proj_kept}"
cat > "${proj_kept}/logger.ts" <<'EOF'
export function log(msg: string): void {
  console.log(msg); // keep
}
EOF
assert_ok "console.log with // keep is not flagged" bash "$GUARD" "$proj_kept"

# --- PASS/FAIL: fixtures excluded by default, but includable via flag ---
proj_fixtures="${tmpdir}/fixtures_scope"
mkdir -p "${proj_fixtures}/tests/fixtures"
cat > "${proj_fixtures}/tests/fixtures/debug.ts" <<'EOF'
console.log("fixture debug");
EOF
assert_ok "tests/fixtures debug code is ignored by default" bash "$GUARD" "$proj_fixtures"
assert_fail "tests/fixtures debug code is scanned with --include-fixtures" bash "$GUARD" --include-fixtures "$proj_fixtures"
assert_fail "tests/fixtures debug code is scanned with --strict-repo" bash "$GUARD" --strict-repo "$proj_fixtures"

# --- VibeGuard self-scan precision: repo-local, category-local, line-scoped ---
proj_self_scan="${tmpdir}/vibeguard_self_scan"
mkdir -p \
  "${proj_self_scan}/guards" \
  "${proj_self_scan}/hooks" \
  "${proj_self_scan}/vibeguard-runtime/src" \
  "${proj_self_scan}/other"
: > "${proj_self_scan}/.vibeguard-doc-paths-allowlist"
cat > "${proj_self_scan}/vibeguard-runtime/src/main.rs" <<'EOF'
fn main() {
    println!("cli product output");
    dbg!("runtime diagnostic");
    println!("cli output"); dbg!("same-line diagnostic"); println!("{}", dbg!("nested diagnostic"));
    println!("dbg!( is product text, not a macro");
    dbg!("trace.rs:12: println!(\"x\")");
    println!("cli output"); let value: &'static str = dbg!("lifetime diagnostic"); dbg! ("spaced diagnostic");
}
EOF
cat > "${proj_self_scan}/vibeguard-runtime/src/hook_checks_common.rs" <<'EOF'
const DETECTOR_PATTERN: &str = "todo!("; // slop-pattern-source
// slop-pattern-source
const ADJACENT_PATTERN: &str = "unimplemented!(";
fn unfinished() {
    todo!();
}
EOF
cat > "${proj_self_scan}/other/client.ts" <<'EOF'
console.log("other category remains visible"); // slop-pattern-source
EOF

assert_fail "self-scan retains unsuppressed findings" bash "$GUARD" "$proj_self_scan"
assert_output_not_contains "self-scan suppresses runtime CLI println" 'println!("cli product output")' bash "$GUARD" "$proj_self_scan"
assert_output_contains "self-scan retains runtime dbg" 'dbg!("runtime diagnostic")' bash "$GUARD" "$proj_self_scan"
assert_output_contains "self-scan retains dbg after same-line println" 'dbg!("same-line diagnostic")' bash "$GUARD" "$proj_self_scan"
assert_output_contains "self-scan retains dbg nested in println" 'dbg!("nested diagnostic")' bash "$GUARD" "$proj_self_scan"
assert_output_not_contains "self-scan ignores dbg text inside println string" 'dbg!( is product text' bash "$GUARD" "$proj_self_scan"
assert_output_contains "self-scan retains leading dbg containing line-like text" 'trace.rs:12: println!' bash "$GUARD" "$proj_self_scan"
assert_output_contains "self-scan retains dbg after Rust lifetime" 'dbg!("lifetime diagnostic")' bash "$GUARD" "$proj_self_scan"
assert_output_contains "self-scan retains dbg with spaced delimiter" 'dbg! ("spaced diagnostic")' bash "$GUARD" "$proj_self_scan"
assert_output_not_contains "self-scan suppresses same-line detector marker" 'const DETECTOR_PATTERN' bash "$GUARD" "$proj_self_scan"
assert_output_contains "adjacent marker does not suppress dead-code finding" 'const ADJACENT_PATTERN' bash "$GUARD" "$proj_self_scan"
assert_output_contains "unmarked real stub remains visible" 'todo!();' bash "$GUARD" "$proj_self_scan"
assert_output_contains "marker does not suppress another category" 'console.log("other category remains visible")' bash "$GUARD" "$proj_self_scan"
assert_output_contains "strict self-scan restores runtime println" 'println!("cli product output")' bash "$GUARD" --strict-repo "$proj_self_scan"
assert_output_contains "strict self-scan restores marked detector line" 'const DETECTOR_PATTERN' bash "$GUARD" --strict-repo "$proj_self_scan"

# Keep the outside-runtime assertion isolated from the guard's five-line
# display cap so additional retained runtime diagnostics cannot mask it.
proj_outside_debug="${tmpdir}/outside_runtime_debug"
mkdir -p \
  "${proj_outside_debug}/guards" \
  "${proj_outside_debug}/hooks" \
  "${proj_outside_debug}/vibeguard-runtime/src" \
  "${proj_outside_debug}/other"
: > "${proj_outside_debug}/.vibeguard-doc-paths-allowlist"
printf '%s\n' '    println!("inside product output");' > "${proj_outside_debug}/vibeguard-runtime/src/main.rs"
printf '%s\n' '    println!("outside runtime output");' > "${proj_outside_debug}/other/main.rs"
assert_output_contains "self-scan retains println outside runtime src" 'println!("outside runtime output")' bash "$GUARD" "$proj_outside_debug"

# A target with only two self-scan markers is an ordinary repo.  Neither the
# runtime path nor marker text is a general-purpose suppression contract.
proj_partial_marker="${tmpdir}/partial_self_markers"
mkdir -p \
  "${proj_partial_marker}/guards" \
  "${proj_partial_marker}/hooks" \
  "${proj_partial_marker}/vibeguard-runtime/src"
cat > "${proj_partial_marker}/vibeguard-runtime/src/main.rs" <<'EOF'
fn main() {
    println!("ordinary repo output");
}
const PATTERN: &str = "todo!("; // slop-pattern-source
EOF
assert_output_contains "partial-marker repo retains runtime println" 'println!("ordinary repo output")' bash "$GUARD" "$proj_partial_marker"
assert_output_contains "partial-marker repo retains marked dead-code line" 'const PATTERN' bash "$GUARD" "$proj_partial_marker"

# Grep renders findings as path:line:content.  Qualified self-scan filtering
# must preserve literal path characters instead of interpreting them as awk
# escapes or treating a colon in a Rust filename as the line delimiter.
proj_escaped_path="${tmpdir}/vibeguard\\self_scan"
mkdir -p \
  "${proj_escaped_path}/guards" \
  "${proj_escaped_path}/hooks" \
  "${proj_escaped_path}/vibeguard-runtime/src"
: > "${proj_escaped_path}/.vibeguard-doc-paths-allowlist"
cat > "${proj_escaped_path}/vibeguard-runtime/src/cli:main.rs" <<'EOF'
fn main() {
    println!("escaped path product output");
}
EOF
assert_ok "self-scan handles backslash target and colon Rust filename" bash "$GUARD" "$proj_escaped_path"

echo
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' "$TOTAL" "$PASS" "$FAIL"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0

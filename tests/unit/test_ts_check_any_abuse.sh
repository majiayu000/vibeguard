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
assert_output_contains "output contains TS-02 tag for ts-ignore" "[TS-02]" bash "$GUARD" --strict "$proj_ts_ignore"

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
assert_output_contains "output contains TS-02 tag for nocheck" "[TS-02]" bash "$GUARD" --strict "$proj_ts_nocheck"

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

# --- PASS: an object value named `any` is not a type annotation ---
proj_object="${tmpdir}/pass_any_object_value"
mkdir -p "${proj_object}/src"
cat > "${proj_object}/src/value.ts" <<'EOF'
declare const any: unknown;
export const payload = { value: any };
export function payloadForReturn() { return { value: any }; }
export function sendPayload(consume: (value: object) => void) { consume({ value: any }); }
EOF
assert_ok "object values named any pass in assignments, returns, and arguments" bash "$GUARD" --strict "$proj_object"

# --- PASS: nested object values named any are still values, not annotations ---
proj_nested_object="${tmpdir}/pass_nested_any_object_value"
mkdir -p "${proj_nested_object}/src"
cat > "${proj_nested_object}/src/value.ts" <<'EOF'
declare const any: unknown;
export const payload = { nested: { item: any } };
EOF
assert_ok "nested object values named any pass" bash "$GUARD" --strict "$proj_nested_object"

# --- PASS: any used as a ternary value is not a type annotation ---
proj_ternary="${tmpdir}/pass_ternary_any_value"
mkdir -p "${proj_ternary}/src"
cat > "${proj_ternary}/src/value.ts" <<'EOF'
declare const any: unknown;
declare const condition: boolean;
declare const specific: string;
export const value = condition ? specific : any;
EOF
assert_ok "ternary value named any passes" bash "$GUARD" --strict "$proj_ternary"

# --- PASS: any after switch-case and label colons is a value ---
proj_case_label="${tmpdir}/pass_case_label_any_value"
mkdir -p "${proj_case_label}/src"
cat > "${proj_case_label}/src/value.ts" <<'EOF'
declare const any: unknown;
export function inspect(value: number): void {
  switch (value) { case 1: any; default: break; }
retry: any;
  if (value > 1) { break retry; }
}
EOF
assert_ok "case and label values named any pass" bash "$GUARD" --strict "$proj_case_label"

# --- FAIL: a later annotation colon inside a case clause remains a type ---
proj_case_annotation="${tmpdir}/fail_case_clause_any_type"
mkdir -p "${proj_case_annotation}/src"
cat > "${proj_case_annotation}/src/value.ts" <<'EOF'
declare const input: unknown;
export function inspect(value: number): void {
  switch (value) {
    case 1:
      let result: any = input;
      console.info(result);
  }
}
EOF
assert_fail "any annotation inside a case clause still fails" \
  bash "$GUARD" --strict "$proj_case_annotation"

# --- FAIL: class fields remain type annotations, not labels ---
proj_class_field="${tmpdir}/fail_class_field_any_type"
mkdir -p "${proj_class_field}/src"
cat > "${proj_class_field}/src/value.ts" <<'EOF'
export class Holder {
  value: any;
}
EOF
assert_fail "class fields typed any still fail" bash "$GUARD" --strict "$proj_class_field"

# --- PASS: import/export aliases named any are values, not type assertions ---
proj_alias="${tmpdir}/pass_any_import_alias"
mkdir -p "${proj_alias}/src"
cat > "${proj_alias}/src/value.ts" <<'EOF'
import { value as any } from "./module";
export { value as any } from "./module";
console.info(any);
EOF
assert_ok "import and export aliases named any pass" bash "$GUARD" --strict "$proj_alias"

# --- PASS: object binding aliases named any are values, not type annotations ---
proj_binding_alias="${tmpdir}/pass_any_binding_alias"
mkdir -p "${proj_binding_alias}/src"
cat > "${proj_binding_alias}/src/value.ts" <<'EOF'
declare const source: { value: unknown };
const { value: any } = source;
console.info(any);
EOF
assert_ok "destructuring aliases named any pass" bash "$GUARD" --strict "$proj_binding_alias"

# --- FAIL: semicolon-free imports do not suppress later assertions ---
proj_semicolon_free="${tmpdir}/fail_any_after_semicolon_free_import"
mkdir -p "${proj_semicolon_free}/src"
cat > "${proj_semicolon_free}/src/value.ts" <<'EOF'
import { value } from "./module"
declare const input: unknown
export const escaped = input as any
EOF
assert_fail "as-any after a semicolon-free import remains visible" \
  bash "$GUARD" --strict "$proj_semicolon_free"

# --- FAIL: multiline type annotations and casts preserve syntax-level coverage ---
proj_multiline_any="${tmpdir}/fail_multiline_any"
mkdir -p "${proj_multiline_any}/src"
cat > "${proj_multiline_any}/src/value.ts" <<'EOF'
declare const input: unknown;
export const annotated:
  any = input;
export const cast = input as
  any;
EOF
assert_fail "multiline any annotation and cast fail --strict" bash "$GUARD" --strict "$proj_multiline_any"

# --- FAIL: JSX closing tags do not hide later TypeScript syntax ---
proj_tsx="${tmpdir}/fail_tsx_after_closing_tag"
mkdir -p "${proj_tsx}/src"
cat > "${proj_tsx}/src/component.tsx" <<'EOF'
export const view = <div>ready</div>;
export const payload: any = view;
EOF
assert_fail "any after JSX closing tag fails --strict" bash "$GUARD" --strict "$proj_tsx"

# --- PASS/FAIL: JSX display text is masked while brace expressions stay executable ---
proj_jsx_text="${tmpdir}/jsx_text_any"
mkdir -p "${proj_jsx_text}/src"
cat > "${proj_jsx_text}/src/clean.tsx" <<'EOF'
export const Help = () => <p>Input: any value</p>;
EOF
assert_ok "any in JSX display text passes" bash "$GUARD" --strict "$proj_jsx_text"
cat > "${proj_jsx_text}/src/clean.tsx" <<'EOF'
declare const input: unknown;
export const Help = () => <p>{input as any}</p>;
EOF
assert_fail "as-any inside a JSX expression remains visible" \
  bash "$GUARD" --strict "$proj_jsx_text"

# --- FAIL: TSX generic arrows are expressions, not opening JSX tags ---
proj_tsx_generic_arrow="${tmpdir}/fail_tsx_generic_arrow_any"
mkdir -p "${proj_tsx_generic_arrow}/src"
cat > "${proj_tsx_generic_arrow}/src/value.tsx" <<'EOF'
export const identity = <T,>(value: T) => value;
export const payload: any = identity("value");
EOF
assert_fail "any after a TSX generic arrow remains visible" \
  bash "$GUARD" --strict "$proj_tsx_generic_arrow"

# --- FAIL: division after a postfix operator must not mask later source ---
proj_postfix_division="${tmpdir}/fail_any_after_postfix_division"
mkdir -p "${proj_postfix_division}/src"
cat > "${proj_postfix_division}/src/value.ts" <<'EOF'
declare let index: number;
declare const total: number;
export const ratio = index++ / total;
export const payload: any = ratio;
EOF
assert_fail "any after postfix-operator division remains visible" \
  bash "$GUARD" --strict "$proj_postfix_division"

# --- FAIL: division after a postfix non-null assertion must not mask later source ---
proj_nonnull_division="${tmpdir}/fail_any_after_nonnull_division"
mkdir -p "${proj_nonnull_division}/src"
cat > "${proj_nonnull_division}/src/value.ts" <<'EOF'
declare const value: number | undefined;
declare const total: number;
export const ratio = value! / total;
export const payload: any = ratio;
EOF
assert_fail "any after postfix non-null division remains visible" \
  bash "$GUARD" --strict "$proj_nonnull_division"

# --- FAIL: division after a quoted literal must not mask later source ---
proj_string_division="${tmpdir}/fail_any_after_string_division"
mkdir -p "${proj_string_division}/src"
cat > "${proj_string_division}/src/value.ts" <<'EOF'
declare const total: number;
export const ratio = "10" / total;
export const payload: any = ratio;
EOF
assert_fail "any after quoted-literal division remains visible" \
  bash "$GUARD" --strict "$proj_string_division"

# --- FAIL: any nested inside generic type annotations is still a type node ---
proj_nested_type="${tmpdir}/fail_nested_any_type"
mkdir -p "${proj_nested_type}/src"
cat > "${proj_nested_type}/src/value.ts" <<'EOF'
declare const input: unknown;
export const values: Array<any> = [];
export const result: Promise<Result<string, any>> = Promise.resolve(input as any);
EOF
assert_fail "any nested inside generic type annotations fails --strict" \
  bash "$GUARD" --strict "$proj_nested_type"

# --- FAIL: tuple commas remain inside the surrounding type annotation ---
proj_tuple_type="${tmpdir}/fail_tuple_any_type"
mkdir -p "${proj_tuple_type}/src"
cat > "${proj_tuple_type}/src/value.ts" <<'EOF'
declare const value: unknown;
export const pair: [string, any] = value as [string, unknown];
EOF
assert_fail "any inside tuple type annotations fails --strict" bash "$GUARD" --strict "$proj_tuple_type"

# --- FAIL: object type members remain type annotations ---
proj_object_type="${tmpdir}/fail_any_object_type"
mkdir -p "${proj_object_type}/src"
cat > "${proj_object_type}/src/value.ts" <<'EOF'
export type Payload = { value: any };
export function read(): { value: any } { throw new Error("not implemented"); }
EOF
assert_fail "object type members named any still fail" bash "$GUARD" --strict "$proj_object_type"

# --- PASS: test files are excluded ---
proj_test_excluded="${tmpdir}/pass_test_excluded"
mkdir -p "${proj_test_excluded}/src"
cat > "${proj_test_excluded}/src/component.test.ts" <<'EOF'
const data = something as any;
// @ts-ignore
const x: any = 42;
EOF
assert_ok "violations in .test.ts files are excluded" bash "$GUARD" --strict "$proj_test_excluded"

# --- FAIL: staged mode works when bash mapfile is unavailable ---
proj_staged_no_mapfile="${tmpdir}/fail_staged_no_mapfile"
mkdir -p "${proj_staged_no_mapfile}/src"
proj_staged_no_mapfile="$(cd "${proj_staged_no_mapfile}" && pwd -P)"
git -C "${proj_staged_no_mapfile}" init -q
cat > "${proj_staged_no_mapfile}/src/staged.ts" <<'EOF'
export const value = input as any;
EOF
git -C "${proj_staged_no_mapfile}" add src/staged.ts
staged_no_mapfile_list="${tmpdir}/ts_any_staged_files.txt"
printf '%s\n' "${proj_staged_no_mapfile}/src/staged.ts" > "$staged_no_mapfile_list"
disable_mapfile_env="${tmpdir}/disable_mapfile.bashenv"
printf '%s\n' 'enable -n mapfile 2>/dev/null || true' > "$disable_mapfile_env"
ast_grep_stub_dir="${tmpdir}/ast_grep_stub_ts_any"
mkdir -p "$ast_grep_stub_dir"
cat > "$ast_grep_stub_dir/ast-grep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target="${!#}"
printf '[{"file":"%s","range":{"start":{"line":0}},"message":"stub any usage"}]\n' "$target"
EOF
chmod +x "$ast_grep_stub_dir/ast-grep"
assert_output_contains "staged mode without mapfile uses Rust target collection" "[TS-01]" \
  env PATH="$ast_grep_stub_dir:$PATH" BASH_ENV="$disable_mapfile_env" VIBEGUARD_STAGED_FILES="$staged_no_mapfile_list" \
  bash "$GUARD" --strict "$proj_staged_no_mapfile"

# --- PASS: recursive collection does not follow directory symlinks ---
proj_symlink="${tmpdir}/pass_symlink_boundary"
outside_symlink="${tmpdir}/outside_ts"
mkdir -p "${proj_symlink}/src" "$outside_symlink"
printf 'export const clean: string = "ok";\n' > "${proj_symlink}/src/clean.ts"
printf 'export const escaped: any = 1;\n' > "${outside_symlink}/escaped.ts"
if ln -s "$outside_symlink" "${proj_symlink}/escape" 2>/dev/null \
    && ln -s "$proj_symlink" "${proj_symlink}/cycle" 2>/dev/null; then
assert_ok "directory symlink escapes and cycles are not scanned" bash "$GUARD" --strict "$proj_symlink"
fi

# --- FAIL: standalone scans include source-file symlinks without following directories ---
proj_file_symlink="${tmpdir}/fail_file_symlink"
outside_file_symlink="${tmpdir}/outside_file_symlink.ts"
mkdir -p "${proj_file_symlink}/src"
printf 'export const linked: any = 1;\n' > "$outside_file_symlink"
if ln -s "$outside_file_symlink" "${proj_file_symlink}/src/linked.ts" 2>/dev/null; then
  assert_fail "standalone scan includes a source-file symlink" \
    bash "$GUARD" --strict "$proj_file_symlink"
fi

# --- FAIL: standalone scans include untracked source files in Git worktrees ---
proj_untracked="${tmpdir}/fail_untracked_source"
mkdir -p "${proj_untracked}/src"
git -C "$proj_untracked" init -q
git -C "$proj_untracked" config user.email "vibeguard-tests@example.invalid"
git -C "$proj_untracked" config user.name "VibeGuard Tests"
printf 'export const tracked: string = "ok";\n' > "${proj_untracked}/src/tracked.ts"
git -C "$proj_untracked" add src/tracked.ts
git -C "$proj_untracked" commit -q -m initial
printf 'export const untracked: any = 1;\n' > "${proj_untracked}/src/untracked.ts"
assert_fail "standalone scan reports an untracked source violation" \
  bash "$GUARD" --strict "$proj_untracked"

# --- PASS: standalone scans exclude harness-owned copied worktrees ---
proj_harness="${tmpdir}/pass_harness_worktree_exclusion"
mkdir -p "${proj_harness}/src" "${proj_harness}/.harness/worktrees/copy/src"
printf 'export const clean: string = "ok";\n' > "${proj_harness}/src/clean.ts"
printf 'export const copied: any = 1;\n' > "${proj_harness}/.harness/worktrees/copy/src/copied.ts"
assert_ok "standalone scan excludes .harness/worktrees" \
  bash "$GUARD" --strict "$proj_harness"

# --- PASS: empty project ---
proj_empty="${tmpdir}/pass_empty"
mkdir -p "${proj_empty}/src"
assert_ok "empty project passes" bash "$GUARD" --strict "$proj_empty"

echo
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' "$TOTAL" "$PASS" "$FAIL"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0

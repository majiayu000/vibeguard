#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
source "${SCRIPT_DIR}/../lib/precommit_fixtures.sh"
hook_test_init

# JS-only changes inside a TS repo must still run tsc when tsconfig.json is present.
tmp_repo_precommit_ts_js="$(mktemp -d)"
git -C "$tmp_repo_precommit_ts_js" init -q
mkdir -p "$tmp_repo_precommit_ts_js/bin" "$tmp_repo_precommit_ts_js/src"

cat >"$tmp_repo_precommit_ts_js/tsconfig.json" <<'EOF'
{
  "compilerOptions": {
    "allowJs": true,
    "checkJs": true,
    "noEmit": true
  },
  "include": ["src/**/*"]
}
EOF

cat >"$tmp_repo_precommit_ts_js/src/bad.js" <<'EOF'
const value = missingSymbol;
EOF

cat >"$tmp_repo_precommit_ts_js/bin/node" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$tmp_repo_precommit_ts_js/bin/tsc" <<'EOF'
#!/usr/bin/env bash
echo "simulated tsc stderr: cannot find name missingSymbol" >&2
exit 1
EOF

chmod +x "$tmp_repo_precommit_ts_js/bin/node" "$tmp_repo_precommit_ts_js/bin/tsc"
git -C "$tmp_repo_precommit_ts_js" add tsconfig.json src/bad.js
_stub_guards="$(make_stub_guard_dir)"
assert_exit_nonzero "JS-only staged changes in a TS repo still run tsc --noEmit" bash -c "cd '$tmp_repo_precommit_ts_js' && PATH='$tmp_repo_precommit_ts_js/bin:/usr/bin:/bin:$PATH' VIBEGUARD_DIR='$_stub_guards' bash '$REPO_DIR/hooks/pre-commit-guard.sh'"
ts_build_diag_out=$(cd "$tmp_repo_precommit_ts_js" && PATH="$tmp_repo_precommit_ts_js/bin:/usr/bin:/bin:$PATH" VIBEGUARD_DIR="$_stub_guards" bash "$REPO_DIR/hooks/pre-commit-guard.sh" 2>&1 || true)
assert_contains "$ts_build_diag_out" "Build failed:" "TypeScript build failure prints build section"
assert_contains "$ts_build_diag_out" "tsc command:" "TypeScript build failure includes resolved tsc command"
assert_contains "$ts_build_diag_out" "simulated tsc stderr" "TypeScript build failure includes stderr excerpt"
rm -rf "$_stub_guards" "$tmp_repo_precommit_ts_js"

# Mixed TS + JS staged changes should only run the shared TS quality guards once.
tmp_repo_precommit_ts_js_quality_once="$(mktemp -d)"
git -C "$tmp_repo_precommit_ts_js_quality_once" init -q
mkdir -p "$tmp_repo_precommit_ts_js_quality_once/bin" "$tmp_repo_precommit_ts_js_quality_once/src"

cat >"$tmp_repo_precommit_ts_js_quality_once/src/app.ts" <<'EOF'
export const value: number = 1;
EOF

cat >"$tmp_repo_precommit_ts_js_quality_once/src/util.js" <<'EOF'
export const util = 1;
EOF

cat >"$tmp_repo_precommit_ts_js_quality_once/bin/node" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$tmp_repo_precommit_ts_js_quality_once/bin/node"
git -C "$tmp_repo_precommit_ts_js_quality_once" add src/app.ts src/util.js
_stub_guards="$(make_stub_guard_dir)"
cat >"$_stub_guards/guards/typescript/check_console_residual.sh" <<'EOF'
#!/usr/bin/env bash
echo ts-console-ran
exit 1
EOF
cat >"$_stub_guards/guards/typescript/check_any_abuse.sh" <<'EOF'
#!/usr/bin/env bash
echo ts-any-ran
exit 1
EOF
chmod +x \
  "$_stub_guards/guards/typescript/check_console_residual.sh" \
  "$_stub_guards/guards/typescript/check_any_abuse.sh"
mixed_ts_js_quality_out=$(cd "$tmp_repo_precommit_ts_js_quality_once" && PATH="$tmp_repo_precommit_ts_js_quality_once/bin:/usr/bin:/bin:$PATH" VIBEGUARD_DIR="$_stub_guards" bash "$REPO_DIR/hooks/pre-commit-guard.sh" 2>&1 || true)
assert_occurrences "$mixed_ts_js_quality_out" "[ts/console]" 1 "Mixed TS+JS staged changes run the shared TS console guard once"
assert_occurrences "$mixed_ts_js_quality_out" "[ts/any]" 1 "Mixed TS+JS staged changes run the shared TS any guard once"
rm -rf "$_stub_guards" "$tmp_repo_precommit_ts_js_quality_once"

# JS files inside a TS project should still run the shared TS quality guards once.
tmp_repo_precommit_js_in_ts_quality_once="$(mktemp -d)"
git -C "$tmp_repo_precommit_js_in_ts_quality_once" init -q
mkdir -p "$tmp_repo_precommit_js_in_ts_quality_once/bin" "$tmp_repo_precommit_js_in_ts_quality_once/src"

cat >"$tmp_repo_precommit_js_in_ts_quality_once/tsconfig.json" <<'EOF'
{
  "compilerOptions": {
    "allowJs": true,
    "checkJs": true,
    "noEmit": true
  },
  "include": ["src/**/*"]
}
EOF

cat >"$tmp_repo_precommit_js_in_ts_quality_once/src/util.js" <<'EOF'
export const util = 1;
EOF

cat >"$tmp_repo_precommit_js_in_ts_quality_once/bin/node" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$tmp_repo_precommit_js_in_ts_quality_once/bin/tsc" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x \
  "$tmp_repo_precommit_js_in_ts_quality_once/bin/node" \
  "$tmp_repo_precommit_js_in_ts_quality_once/bin/tsc"
git -C "$tmp_repo_precommit_js_in_ts_quality_once" add tsconfig.json src/util.js
_stub_guards="$(make_stub_guard_dir)"
cat >"$_stub_guards/guards/typescript/check_console_residual.sh" <<'EOF'
#!/usr/bin/env bash
echo ts-console-ran
exit 1
EOF
cat >"$_stub_guards/guards/typescript/check_any_abuse.sh" <<'EOF'
#!/usr/bin/env bash
echo ts-any-ran
exit 1
EOF
chmod +x \
  "$_stub_guards/guards/typescript/check_console_residual.sh" \
  "$_stub_guards/guards/typescript/check_any_abuse.sh"
js_in_ts_quality_out=$(cd "$tmp_repo_precommit_js_in_ts_quality_once" && PATH="$tmp_repo_precommit_js_in_ts_quality_once/bin:/usr/bin:/bin:$PATH" VIBEGUARD_DIR="$_stub_guards" bash "$REPO_DIR/hooks/pre-commit-guard.sh" 2>&1 || true)
assert_occurrences "$js_in_ts_quality_out" "[ts/console]" 1 "JS-in-TS staged changes run the shared TS console guard once"
assert_occurrences "$js_in_ts_quality_out" "[ts/any]" 1 "JS-in-TS staged changes run the shared TS any guard once"
rm -rf "$_stub_guards" "$tmp_repo_precommit_js_in_ts_quality_once"

hook_test_finish

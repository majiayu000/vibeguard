#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
source "${SCRIPT_DIR}/../lib/precommit_fixtures.sh"
hook_test_init

# Nested Rust crates must run cargo check from the staged file's nearest Cargo.toml.
tmp_repo_precommit_nested_rust="$(mktemp -d)"
git -C "$tmp_repo_precommit_nested_rust" init -q
mkdir -p "$tmp_repo_precommit_nested_rust/bin" "$tmp_repo_precommit_nested_rust/crates/demo/src"

cat >"$tmp_repo_precommit_nested_rust/crates/demo/Cargo.toml" <<'EOF'
[package]
name = "nested-demo"
version = "0.1.0"
edition = "2021"
EOF

cat >"$tmp_repo_precommit_nested_rust/crates/demo/src/lib.rs" <<'EOF'
pub fn demo() -> i32 {
    1
}
EOF

cat >"$tmp_repo_precommit_nested_rust/bin/cargo" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "check" ]]; then
  exit 1
fi
exit 0
EOF

chmod +x "$tmp_repo_precommit_nested_rust/bin/cargo"
git -C "$tmp_repo_precommit_nested_rust" add crates/demo/Cargo.toml crates/demo/src/lib.rs
_stub_guards="$(make_stub_guard_dir)"
assert_exit_nonzero "Nested Cargo.toml projects still run cargo check in pre-commit" bash -c "cd '$tmp_repo_precommit_nested_rust' && PATH='$tmp_repo_precommit_nested_rust/bin:/usr/bin:/bin:$PATH' VIBEGUARD_DIR='$_stub_guards' bash '$REPO_DIR/hooks/pre-commit-guard.sh'"
rm -rf "$_stub_guards" "$tmp_repo_precommit_nested_rust"

# Nested TS apps must run tsc from the staged file's nearest tsconfig.json.
# The compiler may be installed only at the repo root, so the hook must search
# ancestor node_modules/.bin entries instead of skipping the build check.
tmp_repo_precommit_nested_ts="$(mktemp -d)"
git -C "$tmp_repo_precommit_nested_ts" init -q
mkdir -p "$tmp_repo_precommit_nested_ts/bin" "$tmp_repo_precommit_nested_ts/apps/web/src" "$tmp_repo_precommit_nested_ts/node_modules/.bin"

cat >"$tmp_repo_precommit_nested_ts/apps/web/tsconfig.json" <<'EOF'
{
  "compilerOptions": {
    "noEmit": true
  },
  "include": ["src/**/*"]
}
EOF

cat >"$tmp_repo_precommit_nested_ts/apps/web/src/index.ts" <<'EOF'
export const value = 1;
EOF

cat >"$tmp_repo_precommit_nested_ts/node_modules/.bin/tsc" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

chmod +x "$tmp_repo_precommit_nested_ts/node_modules/.bin/tsc"
git -C "$tmp_repo_precommit_nested_ts" add apps/web/tsconfig.json apps/web/src/index.ts
_stub_guards="$(make_stub_guard_dir)"
assert_exit_nonzero "Nested tsconfig.json projects still run tsc --noEmit in pre-commit" bash -c "cd '$tmp_repo_precommit_nested_ts' && PATH='$tmp_repo_precommit_nested_ts/bin:/usr/bin:/bin:$PATH' VIBEGUARD_DIR='$_stub_guards' bash '$REPO_DIR/hooks/pre-commit-guard.sh'"
rm -rf "$_stub_guards" "$tmp_repo_precommit_nested_ts"

# JS syntax checks must not skip staged files whose names contain spaces.
tmp_repo_precommit_js_space="$(mktemp -d)"
git -C "$tmp_repo_precommit_js_space" init -q
mkdir -p "$tmp_repo_precommit_js_space/bin" "$tmp_repo_precommit_js_space/src"

cat >"$tmp_repo_precommit_js_space/src/bad file.js" <<'EOF'
function () {}
EOF

cat >"$tmp_repo_precommit_js_space/bin/node" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--check" ]]; then
  exit 1
fi
exit 0
EOF

chmod +x "$tmp_repo_precommit_js_space/bin/node"
git -C "$tmp_repo_precommit_js_space" add "src/bad file.js"
_stub_guards="$(make_stub_guard_dir)"
assert_exit_nonzero "JavaScript syntax check still runs for staged files with spaces in the path" bash -c "cd '$tmp_repo_precommit_js_space' && PATH='$tmp_repo_precommit_js_space/bin:/usr/bin:/bin:$PATH' VIBEGUARD_DIR='$_stub_guards' bash '$REPO_DIR/hooks/pre-commit-guard.sh'"
rm -rf "$_stub_guards" "$tmp_repo_precommit_js_space"

# JS files under a TS config still need node --check when the tsconfig excludes them.
tmp_repo_precommit_js_outside_tsconfig="$(mktemp -d)"
git -C "$tmp_repo_precommit_js_outside_tsconfig" init -q
mkdir -p "$tmp_repo_precommit_js_outside_tsconfig/bin" "$tmp_repo_precommit_js_outside_tsconfig/src" "$tmp_repo_precommit_js_outside_tsconfig/scripts"

cat >"$tmp_repo_precommit_js_outside_tsconfig/tsconfig.json" <<'EOF'
{
  "compilerOptions": {
    "noEmit": true
  },
  "include": ["src/**/*.ts"]
}
EOF

cat >"$tmp_repo_precommit_js_outside_tsconfig/scripts/bad.js" <<'EOF'
function () {}
EOF

cat >"$tmp_repo_precommit_js_outside_tsconfig/bin/node" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--check" ]]; then
  exit 1
fi
exit 0
EOF

cat >"$tmp_repo_precommit_js_outside_tsconfig/bin/tsc" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$tmp_repo_precommit_js_outside_tsconfig/bin/node" "$tmp_repo_precommit_js_outside_tsconfig/bin/tsc"
git -C "$tmp_repo_precommit_js_outside_tsconfig" add tsconfig.json scripts/bad.js
_stub_guards="$(make_stub_guard_dir)"
assert_exit_nonzero "JavaScript syntax check still runs when a staged JS file sits outside tsconfig include globs" bash -c "cd '$tmp_repo_precommit_js_outside_tsconfig' && PATH='$tmp_repo_precommit_js_outside_tsconfig/bin:/usr/bin:/bin:$PATH' VIBEGUARD_DIR='$_stub_guards' bash '$REPO_DIR/hooks/pre-commit-guard.sh'"
rm -rf "$_stub_guards" "$tmp_repo_precommit_js_outside_tsconfig"

# .mjs files must be treated as staged source files so node --check can validate them.
tmp_repo_precommit_mjs="$(mktemp -d)"
git -C "$tmp_repo_precommit_mjs" init -q
mkdir -p "$tmp_repo_precommit_mjs/bin"

cat >"$tmp_repo_precommit_mjs/bad.mjs" <<'EOF'
function () {}
EOF

cat >"$tmp_repo_precommit_mjs/bin/node" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--check" ]]; then
  exit 1
fi
exit 0
EOF

chmod +x "$tmp_repo_precommit_mjs/bin/node"
git -C "$tmp_repo_precommit_mjs" add bad.mjs
_stub_guards="$(make_stub_guard_dir)"
assert_exit_nonzero ".mjs files still run JavaScript syntax checks in pre-commit" bash -c "cd '$tmp_repo_precommit_mjs' && PATH='$tmp_repo_precommit_mjs/bin:/usr/bin:/bin:$PATH' VIBEGUARD_DIR='$_stub_guards' bash '$REPO_DIR/hooks/pre-commit-guard.sh'"
rm -rf "$_stub_guards" "$tmp_repo_precommit_mjs"

# Nested TS apps should keep working when only the repo root provides tsc.
tmp_repo_precommit_nested_ts_root_tsc="$(mktemp -d)"
git -C "$tmp_repo_precommit_nested_ts_root_tsc" init -q
mkdir -p "$tmp_repo_precommit_nested_ts_root_tsc/apps/web/src" "$tmp_repo_precommit_nested_ts_root_tsc/node_modules/.bin"

cat >"$tmp_repo_precommit_nested_ts_root_tsc/apps/web/tsconfig.json" <<'EOF'
{
  "compilerOptions": {
    "noEmit": true
  },
  "include": ["src/**/*"]
}
EOF

cat >"$tmp_repo_precommit_nested_ts_root_tsc/apps/web/src/index.ts" <<'EOF'
export const value = missingSymbol;
EOF

cat >"$tmp_repo_precommit_nested_ts_root_tsc/node_modules/.bin/tsc" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

chmod +x "$tmp_repo_precommit_nested_ts_root_tsc/node_modules/.bin/tsc"
git -C "$tmp_repo_precommit_nested_ts_root_tsc" add apps/web/tsconfig.json apps/web/src/index.ts
_stub_guards="$(make_stub_guard_dir)"
assert_exit_nonzero "Nested tsconfig.json projects use repo-root tsc when no nested compiler exists" bash -c "cd '$tmp_repo_precommit_nested_ts_root_tsc' && PATH='/usr/bin:/bin:$PATH' VIBEGUARD_DIR='$_stub_guards' bash '$REPO_DIR/hooks/pre-commit-guard.sh'"
rm -rf "$_stub_guards" "$tmp_repo_precommit_nested_ts_root_tsc"

# Repo-local tsc must win over a globally available compiler for nested TS projects.
tmp_repo_precommit_nested_ts_prefer_local="$(mktemp -d)"
git -C "$tmp_repo_precommit_nested_ts_prefer_local" init -q
mkdir -p "$tmp_repo_precommit_nested_ts_prefer_local/bin" "$tmp_repo_precommit_nested_ts_prefer_local/apps/web/src" "$tmp_repo_precommit_nested_ts_prefer_local/node_modules/.bin"

cat >"$tmp_repo_precommit_nested_ts_prefer_local/apps/web/tsconfig.json" <<'EOF'
{
  "compilerOptions": {
    "noEmit": true
  },
  "include": ["src/**/*"]
}
EOF

cat >"$tmp_repo_precommit_nested_ts_prefer_local/apps/web/src/index.ts" <<'EOF'
export const value = missingSymbol;
EOF

cat >"$tmp_repo_precommit_nested_ts_prefer_local/node_modules/.bin/tsc" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

cat >"$tmp_repo_precommit_nested_ts_prefer_local/bin/tsc" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$tmp_repo_precommit_nested_ts_prefer_local/node_modules/.bin/tsc" "$tmp_repo_precommit_nested_ts_prefer_local/bin/tsc"
git -C "$tmp_repo_precommit_nested_ts_prefer_local" add apps/web/tsconfig.json apps/web/src/index.ts
_stub_guards="$(make_stub_guard_dir)"
assert_exit_nonzero "Nested tsconfig.json projects prefer repo-local tsc over a global compiler" bash -c "cd '$tmp_repo_precommit_nested_ts_prefer_local' && PATH='$tmp_repo_precommit_nested_ts_prefer_local/bin:/usr/bin:/bin:$PATH' VIBEGUARD_DIR='$_stub_guards' bash '$REPO_DIR/hooks/pre-commit-guard.sh'"
rm -rf "$_stub_guards" "$tmp_repo_precommit_nested_ts_prefer_local"

# Nested Go modules must run go build from the staged file's nearest go.mod.
tmp_repo_precommit_nested_go="$(mktemp -d)"
git -C "$tmp_repo_precommit_nested_go" init -q
mkdir -p "$tmp_repo_precommit_nested_go/bin" "$tmp_repo_precommit_nested_go/services/api/cmd"

cat >"$tmp_repo_precommit_nested_go/services/api/go.mod" <<'EOF'
module nested-go-demo

go 1.22
EOF

cat >"$tmp_repo_precommit_nested_go/services/api/cmd/main.go" <<'EOF'
package main

func main() {}
EOF

cat >"$tmp_repo_precommit_nested_go/bin/go" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "build" && "$2" == "./..." ]]; then
  exit 1
fi
exit 0
EOF

chmod +x "$tmp_repo_precommit_nested_go/bin/go"
git -C "$tmp_repo_precommit_nested_go" add services/api/go.mod services/api/cmd/main.go
_stub_guards="$(make_stub_guard_dir)"
assert_exit_nonzero "Nested go.mod projects still run go build ./... in pre-commit" bash -c "cd '$tmp_repo_precommit_nested_go' && PATH='$tmp_repo_precommit_nested_go/bin:/usr/bin:/bin:$PATH' VIBEGUARD_DIR='$_stub_guards' bash '$REPO_DIR/hooks/pre-commit-guard.sh'"
rm -rf "$_stub_guards" "$tmp_repo_precommit_nested_go"

# Build-root discovery must stay inside the repo instead of walking into parent workspaces.
_tmp_precommit_parent_workspace_root="$(mktemp -d)"
_tmp_precommit_parent_workspace_repo="${_tmp_precommit_parent_workspace_root}/repo"
mkdir -p "${_tmp_precommit_parent_workspace_repo}/src" "${_tmp_precommit_parent_workspace_root}/bin"
git -C "${_tmp_precommit_parent_workspace_repo}" init -q

cat >"${_tmp_precommit_parent_workspace_root}/Cargo.toml" <<'EOF'
[package]
name = "outer-workspace"
version = "0.1.0"
edition = "2021"
EOF

cat >"${_tmp_precommit_parent_workspace_repo}/src/lib.rs" <<'EOF'
pub fn demo() -> i32 {
    1
}
EOF

cat >"${_tmp_precommit_parent_workspace_root}/bin/cargo" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "check" ]]; then
  exit 1
fi
exit 0
EOF

chmod +x "${_tmp_precommit_parent_workspace_root}/bin/cargo"
git -C "${_tmp_precommit_parent_workspace_repo}" add src/lib.rs
_stub_guards="$(make_stub_guard_dir)"
assert_exit_zero "Parent-workspace Cargo.toml outside the repo does not affect pre-commit root discovery" bash -c "cd '${_tmp_precommit_parent_workspace_repo}' && PATH='${_tmp_precommit_parent_workspace_root}/bin:/usr/bin:/bin:$PATH' VIBEGUARD_DIR='$_stub_guards' bash '$REPO_DIR/hooks/pre-commit-guard.sh'"
rm -rf "$_stub_guards" "$_tmp_precommit_parent_workspace_root"

# Same-language unstaged manifests/configs must not change staged build-root detection.
_tmp_precommit_unstaged_manifest_repo="$(mktemp -d)"
git -C "$_tmp_precommit_unstaged_manifest_repo" init -q
mkdir -p "$_tmp_precommit_unstaged_manifest_repo/bin" "$_tmp_precommit_unstaged_manifest_repo/src"

cat >"$_tmp_precommit_unstaged_manifest_repo/src/lib.rs" <<'EOF'
pub fn demo() -> i32 {
    1
}
EOF

git -C "$_tmp_precommit_unstaged_manifest_repo" add src/lib.rs

cat >"$_tmp_precommit_unstaged_manifest_repo/Cargo.toml" <<'EOF'
[package]
name = "unstaged-manifest"
version = "0.1.0"
edition = "2021"
EOF

cat >"$_tmp_precommit_unstaged_manifest_repo/bin/cargo" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "check" ]]; then
  exit 1
fi
exit 0
EOF

chmod +x "$_tmp_precommit_unstaged_manifest_repo/bin/cargo"
_stub_guards="$(make_stub_guard_dir)"
assert_exit_zero "Unstaged Cargo.toml does not trigger cargo check for a staged Rust file" bash -c "cd '$_tmp_precommit_unstaged_manifest_repo' && PATH='$_tmp_precommit_unstaged_manifest_repo/bin:/usr/bin:/bin:$PATH' VIBEGUARD_DIR='$_stub_guards' bash '$REPO_DIR/hooks/pre-commit-guard.sh'"
rm -rf "$_stub_guards" "$_tmp_precommit_unstaged_manifest_repo"

hook_test_finish

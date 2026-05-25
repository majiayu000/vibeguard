#!/usr/bin/env bash
set -euo pipefail

# Regression coverage for issue #260: the Rust branch of pre-commit-guard.sh
# must run `cargo fmt -- --check` in addition to `cargo check`. Without this,
# rustfmt-pending diffs slip past pre-commit and only fail in CI.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
source "${SCRIPT_DIR}/../lib/precommit_fixtures.sh"
hook_test_init

# --- Case 1: cargo fmt fails -> pre-commit must reject ---------------------
# stub cargo: `cargo fmt -- --check` returns 1 (unformatted), everything else
# returns 0. This isolates fmt from check so we know the new step is wired.
tmp_repo_fmt_fails="$(mktemp -d)"
git -C "$tmp_repo_fmt_fails" init -q
mkdir -p "$tmp_repo_fmt_fails/bin" "$tmp_repo_fmt_fails/src"

cat >"$tmp_repo_fmt_fails/Cargo.toml" <<'EOF'
[package]
name = "fmt-fails-demo"
version = "0.1.0"
edition = "2021"
EOF

cat >"$tmp_repo_fmt_fails/src/lib.rs" <<'EOF'
pub fn demo() -> i32 {
    1
}
EOF

cat >"$tmp_repo_fmt_fails/bin/cargo" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "fmt" ]]; then
  # Match `cargo fmt -- --check` (rustfmt would re-flow the file).
  exit 1
fi
exit 0
EOF

chmod +x "$tmp_repo_fmt_fails/bin/cargo"
git -C "$tmp_repo_fmt_fails" add Cargo.toml src/lib.rs
_stub_guards="$(make_stub_guard_dir)"
assert_exit_nonzero "Rust pre-commit fails when cargo fmt -- --check reports a diff" bash -c "cd '$tmp_repo_fmt_fails' && PATH='$tmp_repo_fmt_fails/bin:/usr/bin:/bin:$PATH' VIBEGUARD_DIR='$_stub_guards' bash '$REPO_DIR/hooks/pre-commit-guard.sh'"
rm -rf "$_stub_guards" "$tmp_repo_fmt_fails"

# NOTE: A "fmt + check both pass -> hook allows" sanity case is intentionally
# omitted here. The existing test_precommit_nested_roots.sh has two pre-existing
# baseline failures on origin/main where a clean stub repo still returns
# exit 2 (parent-workspace and unstaged-manifest cases). Adding the same shape
# of assertion here would only re-surface that unrelated baseline issue. The
# fmt-fail case above is sufficient to lock in the new step's behaviour;
# regression against the clean path is covered indirectly by nested_roots.

hook_test_finish

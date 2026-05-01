#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
hook_test_init

header "pre-commit-guard.sh — timeout fallback"
# =========================================================

tmp_repo_precommit="$(mktemp -d)"
git -C "$tmp_repo_precommit" init -q
mkdir -p "$tmp_repo_precommit/bin" "$tmp_repo_precommit/src"

cat >"$tmp_repo_precommit/Cargo.toml" <<'EOF'
[package]
name = "vg-precommit-test"
version = "0.1.0"
edition = "2021"
EOF

cat >"$tmp_repo_precommit/src/lib.rs" <<'EOF'
pub fn add(a: i32, b: i32) -> i32 {
    a + b
}
EOF

cat >"$tmp_repo_precommit/bin/timeout" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF

cat >"$tmp_repo_precommit/bin/gtimeout" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF

cat >"$tmp_repo_precommit/bin/cargo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "check" || "${1:-}" == "fmt" ]]; then
  exit 0
fi
exit 1
EOF

chmod +x "$tmp_repo_precommit/bin/timeout" "$tmp_repo_precommit/bin/gtimeout" "$tmp_repo_precommit/bin/cargo"
git -C "$tmp_repo_precommit" add Cargo.toml src/lib.rs

assert_exit_zero "Rewind execution when timeout/gtimeout is unavailable, and do not falsely report build failures" bash -c "cd '$tmp_repo_precommit' && PATH='$tmp_repo_precommit/bin:/usr/bin:/bin:$PATH' bash '$REPO_DIR/hooks/pre-commit-guard.sh'"
rm -rf "$tmp_repo_precommit"

tmp_repo_precommit_timeout="$(mktemp -d)"
git -C "$tmp_repo_precommit_timeout" init -q
mkdir -p "$tmp_repo_precommit_timeout/bin" "$tmp_repo_precommit_timeout/src"

cat >"$tmp_repo_precommit_timeout/Cargo.toml" <<'EOF'
[package]
name = "vg-precommit-timeout-test"
version = "0.1.0"
edition = "2021"
EOF

cat >"$tmp_repo_precommit_timeout/src/lib.rs" <<'EOF'
pub fn add(a: i32, b: i32) -> i32 {
    a + b
}
EOF

cat >"$tmp_repo_precommit_timeout/bin/timeout" <<'EOF'
#!/usr/bin/env bash
exit 124
EOF

chmod +x "$tmp_repo_precommit_timeout/bin/timeout"
git -C "$tmp_repo_precommit_timeout" add Cargo.toml src/lib.rs

> "$VIBEGUARD_LOG_DIR/events.jsonl"
assert_exit_nonzero "Pre-commit timeout blocks by default" bash -c "cd '$tmp_repo_precommit_timeout' && PATH='$tmp_repo_precommit_timeout/bin:/usr/bin:/bin:$PATH' VIBEGUARD_DIR='$REPO_DIR' VIBEGUARD_PRECOMMIT_TIMEOUT=1 bash '$REPO_DIR/hooks/pre-commit-guard.sh'"
assert_contains "$(cat "$VIBEGUARD_LOG_DIR/events.jsonl")" "guard timeout" "Pre-commit timeout writes visible block log"

> "$VIBEGUARD_LOG_DIR/events.jsonl"
assert_exit_zero "Pre-commit timeout can be explicitly downgraded to warn" bash -c "cd '$tmp_repo_precommit_timeout' && PATH='$tmp_repo_precommit_timeout/bin:/usr/bin:/bin:$PATH' VIBEGUARD_DIR='$REPO_DIR' VIBEGUARD_PRECOMMIT_TIMEOUT=1 VIBEGUARD_PRECOMMIT_TIMEOUT_BEHAVIOR=warn bash '$REPO_DIR/hooks/pre-commit-guard.sh'"
assert_contains "$(cat "$VIBEGUARD_LOG_DIR/events.jsonl")" '"decision": "warn"' "Pre-commit timeout downgrade writes warning log"
rm -rf "$tmp_repo_precommit_timeout"

# Go projects should run Go guards (new _ = prevent commits when discarding error)
tmp_repo_precommit_go="$(mktemp -d)"
git -C "$tmp_repo_precommit_go" init -q
mkdir -p "$tmp_repo_precommit_go/bin" "$tmp_repo_precommit_go/cmd"

cat >"$tmp_repo_precommit_go/go.mod" <<'EOF'
module vg-precommit-go-test

go 1.22
EOF

cat >"$tmp_repo_precommit_go/cmd/main.go" <<'EOF'
package main

func doThing() error { return nil }

func main() {
	_ = doThing()
}
EOF

cat >"$tmp_repo_precommit_go/bin/go" <<'EOF'
#!/usr/bin/env bash
# go build in pre-commit is only used as a build access control. Success is returned here to avoid relying on native Go.
exit 0
EOF

chmod +x "$tmp_repo_precommit_go/bin/go"
git -C "$tmp_repo_precommit_go" add go.mod cmd/main.go

assert_exit_nonzero "Go guards prevent _= discarding commits with error" bash -c "cd '$tmp_repo_precommit_go' && PATH='$tmp_repo_precommit_go/bin:/usr/bin:/bin:$PATH' bash '$REPO_DIR/hooks/pre-commit-guard.sh'"
rm -rf "$tmp_repo_precommit_go"

hook_test_finish

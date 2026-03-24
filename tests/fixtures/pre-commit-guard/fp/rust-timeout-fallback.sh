#!/bin/bash
# Rust 项目：timeout/gtimeout 不可用时回退执行，不误报
tmp=$(mktemp -d)
# 注意：不设 trap，runner 负责清理 CWD
git -C "$tmp" init -q
mkdir -p "$tmp/bin" "$tmp/src"

cat >"$tmp/Cargo.toml" <<'EOF'
[package]
name = "vg-precommit-test"
version = "0.1.0"
edition = "2021"
EOF

cat >"$tmp/src/lib.rs" <<'EOF'
pub fn add(a: i32, b: i32) -> i32 {
    a + b
}
EOF

cat >"$tmp/bin/timeout" <<'SCRIPT'
#!/usr/bin/env bash
exit 127
SCRIPT

cat >"$tmp/bin/gtimeout" <<'SCRIPT'
#!/usr/bin/env bash
exit 127
SCRIPT

cat >"$tmp/bin/cargo" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "${1:-}" == "check" || "${1:-}" == "fmt" ]]; then
  exit 0
fi
exit 1
SCRIPT

chmod +x "$tmp/bin/timeout" "$tmp/bin/gtimeout" "$tmp/bin/cargo"
git -C "$tmp" add Cargo.toml src/lib.rs

echo "CWD=$tmp"
echo "EXTRA_PATH=$tmp/bin"
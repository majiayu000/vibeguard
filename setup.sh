#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v cargo >/dev/null 2>&1; then
  cat >&2 <<EOF
VibeGuard: setup.sh builds from source and needs the Rust toolchain (cargo), which was not found.
Install the prebuilt release instead; it needs no Rust toolchain:
  bash "$repo_root/install.sh" <claude|codex|grok> [install options]
Or install Rust from https://rustup.rs and rerun setup.sh.
EOF
  exit 1
fi
exec cargo run --locked --release --manifest-path "$repo_root/vibeguard-runtime/Cargo.toml" -- "$@"

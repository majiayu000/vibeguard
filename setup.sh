#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cargo build --locked --release --manifest-path "$repo_root/vibeguard-runtime/Cargo.toml"
exec "$repo_root/vibeguard-runtime/target/release/vibeguard-runtime" "$@"

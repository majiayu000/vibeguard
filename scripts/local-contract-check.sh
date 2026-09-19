#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
if (($#)); then
  echo "Usage: bash scripts/local-contract-check.sh" >&2
  exit 2
fi
python3 scripts/generate_rule_docs.py --check
python3 -m unittest discover -s tests -p 'test_*.py'
bash scripts/ci/validate-doc-paths.sh
bash scripts/ci/validate-doc-command-paths.sh
cargo fmt --manifest-path vibeguard-runtime/Cargo.toml -- --check
cargo check --locked --manifest-path vibeguard-runtime/Cargo.toml
cargo clippy --locked --manifest-path vibeguard-runtime/Cargo.toml --all-targets -- -D warnings
cargo test --locked --manifest-path vibeguard-runtime/Cargo.toml
cargo build --locked --release --manifest-path vibeguard-runtime/Cargo.toml
python3 scripts/ci/smoke_binary.py vibeguard-runtime/target/release/vibeguard-runtime
git diff --check

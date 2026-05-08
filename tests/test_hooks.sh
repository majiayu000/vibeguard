#!/usr/bin/env bash
# VibeGuard Hook Test Suite orchestrator.
# Runs discoverable per-hook regression shards under tests/hooks/.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

if [[ -n "${VIBEGUARD_TEST_UPDATED_INPUT:-}" ]] \
    && [[ -f "vg-helper/Cargo.toml" ]] \
    && [[ ! -x "vg-helper/target/release/vg-helper" ]]; then
  if ! command -v cargo >/dev/null 2>&1; then
    echo "VIBEGUARD_TEST_UPDATED_INPUT requires cargo to build vg-helper" >&2
    exit 2
  fi
  cargo build --release --manifest-path vg-helper/Cargo.toml --quiet
fi

shards=(
  "tests/hooks/test_log_injection.sh"
  "tests/hooks/test_pre_bash_guard.sh"
  "tests/hooks/test_pre_push_guard.sh"
  "tests/hooks/test_pre_edit_guard.sh"
  "tests/hooks/test_pre_write_guard.sh"
  "tests/hooks/test_post_edit_guard_basic.sh"
  "tests/hooks/test_post_write_guard.sh"
  "tests/hooks/test_post_build_check.sh"
  "tests/hooks/test_precommit_timeout_go.sh"
  "tests/hooks/test_precommit_ts_quality.sh"
  "tests/hooks/test_precommit_nested_roots.sh"
  "tests/hooks/test_log_session.sh"
  "tests/hooks/test_post_edit_suppression.sh"
  "tests/hooks/test_log_timer.sh"
  "tests/hooks/test_post_edit_w14.sh"
  "tests/hooks/test_post_edit_w15.sh"
)

for shard in "${shards[@]}"; do
  echo
  echo "--- ${shard} ---"
  bash "${shard}"
done

echo
echo "All hook test shards passed."

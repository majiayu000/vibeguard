#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
hook_test_init

header "U-16 baseline-aware staged and CI enforcement"

WORK_ROOT=$(mktemp -d)
trap 'rm -rf "$WORK_ROOT" "$VIBEGUARD_LOG_DIR"' EXIT

runtime="${VIBEGUARD_RUNTIME:-${REPO_DIR}/vibeguard-runtime/target/debug/vibeguard-runtime}"
if [[ ! -x "$runtime" ]]; then
  runtime="${REPO_DIR}/vibeguard-runtime/target/release/vibeguard-runtime"
fi
if [[ ! -x "$runtime" ]]; then
  echo "test_u16_baseline.sh requires vibeguard-runtime; run cargo build --manifest-path vibeguard-runtime/Cargo.toml" >&2
  exit 2
fi

make_repo() {
  local name="$1"
  local repo="$WORK_ROOT/$name"
  mkdir -p "$repo/src"
  git -C "$repo" init -q
  git -C "$repo" config user.name "VibeGuard Test"
  git -C "$repo" config user.email "test@vibeguard.local"
  printf '%s\n' "$repo"
}

write_lines() {
  local path="$1" count="$2" prefix="${3:-line}"
  python3 - "$path" "$count" "$prefix" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
count = int(sys.argv[2])
prefix = sys.argv[3]
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text("".join(f"// {prefix} {i}\n" for i in range(count)), encoding="utf-8")
PY
}

commit_all() {
  local repo="$1" message="$2"
  git -C "$repo" add .
  git -C "$repo" commit -q -m "$message"
}

run_staged() {
  local repo="$1"
  (cd "$repo" && VIBEGUARD_RUNTIME="$runtime" "$runtime" u16-baseline-check --staged)
}

capture_staged() {
  local repo="$1"
  set +e
  CAPTURED_OUTPUT="$(run_staged "$repo" 2>&1)"
  CAPTURED_STATUS=$?
  set -e
}

repo="$(make_repo initial)"
write_lines "$repo/src/new_big.rs" 801
git -C "$repo" add src/new_big.rs
capture_staged "$repo"
assert_contains "status=$CAPTURED_STATUS" "status=1" "initial oversized source file blocks"
assert_contains "$CAPTURED_OUTPUT" "new_oversized" "initial oversized source file names block reason"

repo="$(make_repo crossing)"
write_lines "$repo/src/lib.rs" 800
commit_all "$repo" "baseline"
write_lines "$repo/src/lib.rs" 801 "cross"
git -C "$repo" add src/lib.rs
capture_staged "$repo"
assert_contains "status=$CAPTURED_STATUS" "status=1" "799/800-era source crossing hard limit blocks"
assert_contains "$CAPTURED_OUTPUT" "crosses_limit" "crossing hard limit names block reason"

repo="$(make_repo growth)"
write_lines "$repo/src/legacy.rs" 1463
commit_all "$repo" "legacy"
write_lines "$repo/src/legacy.rs" 1464 "grow"
git -C "$repo" add src/legacy.rs
capture_staged "$repo"
assert_contains "status=$CAPTURED_STATUS" "status=1" "legacy oversized file growth blocks"
assert_contains "$CAPTURED_OUTPUT" "legacy_growth" "legacy growth names block reason"

repo="$(make_repo same-size)"
write_lines "$repo/src/legacy.rs" 1463
commit_all "$repo" "legacy"
write_lines "$repo/src/legacy.rs" 1463 "same-size-fix"
git -C "$repo" add src/legacy.rs
capture_staged "$repo"
assert_contains "status=$CAPTURED_STATUS" "status=0" "legacy same-size edit is allowed"
assert_contains "$CAPTURED_OUTPUT" "U16_LEGACY_DEBT" "legacy same-size edit emits debt advisory"

repo="$(make_repo shrink)"
write_lines "$repo/src/legacy.rs" 1463
commit_all "$repo" "legacy"
write_lines "$repo/src/legacy.rs" 1200 "shrink"
git -C "$repo" add src/legacy.rs
capture_staged "$repo"
assert_contains "status=$CAPTURED_STATUS" "status=0" "legacy shrinking edit is allowed"
assert_contains "$CAPTURED_OUTPUT" "U16_LEGACY_DEBT" "legacy shrinking edit emits debt advisory"

repo="$(make_repo below-limit)"
write_lines "$repo/src/legacy.rs" 1463
commit_all "$repo" "legacy"
write_lines "$repo/src/legacy.rs" 799 "below"
git -C "$repo" add src/legacy.rs
capture_staged "$repo"
assert_contains "status=$CAPTURED_STATUS" "status=0" "legacy split below hard limit is allowed"
assert_not_contains "$CAPTURED_OUTPUT" "U16_LEGACY_DEBT" "legacy split below hard limit has no debt advisory"

repo="$(make_repo unchanged)"
write_lines "$repo/src/legacy.rs" 1463
commit_all "$repo" "legacy"
write_lines "$repo/src/small.rs" 10 "small"
git -C "$repo" add src/small.rs
capture_staged "$repo"
assert_contains "status=$CAPTURED_STATUS" "status=0" "unchanged legacy oversized file is ignored"
assert_contains "$CAPTURED_OUTPUT" "U16_BASELINE_OK" "unchanged legacy oversized file does not emit debt"

repo="$(make_repo rename)"
write_lines "$repo/src/legacy.rs" 1463
commit_all "$repo" "legacy"
git -C "$repo" mv src/legacy.rs src/renamed.rs
capture_staged "$repo"
assert_contains "status=$CAPTURED_STATUS" "status=0" "rename without growth is allowed"
assert_contains "$CAPTURED_OUTPUT" "U16_LEGACY_DEBT" "rename keeps legacy baseline"

repo="$(make_repo exempt)"
printf '%s\n' 'U-16 exempt `src/generated.rs` 1500' > "$repo/CLAUDE.md"
commit_all "$repo" "exemption"
write_lines "$repo/src/generated.rs" 1200 "generated"
git -C "$repo" add src/generated.rs
capture_staged "$repo"
assert_contains "status=$CAPTURED_STATUS" "status=0" "explicit U-16 exemption allows configured oversized file"
assert_contains "$CAPTURED_OUTPUT" "U16_BASELINE_OK" "explicit U-16 exemption uses shared decision"

repo="$(make_repo precommit)"
write_lines "$repo/src/new_big.rs" 801
git -C "$repo" add src/new_big.rs
set +e
precommit_output="$(cd "$repo" && VIBEGUARD_RUNTIME="$runtime" bash "$REPO_DIR/hooks/pre-commit-guard.sh" 2>&1)"
precommit_status=$?
set -e
assert_contains "status=$precommit_status" "status=1" "pre-commit blocks staged oversized source import"
assert_contains "$precommit_output" "U16_BASELINE_BLOCK" "pre-commit prints U-16 baseline block evidence"

repo="$(make_repo precommit-standalone)"
standalone_hook_dir="$WORK_ROOT/standalone-hook"
mkdir -p "$standalone_hook_dir"
cp "$REPO_DIR/hooks/pre-commit-guard.sh" "$standalone_hook_dir/pre-commit-guard.sh"
write_lines "$repo/src/new_big.rs" 801
git -C "$repo" add src/new_big.rs
set +e
standalone_precommit_output="$(cd "$repo" && VIBEGUARD_RUNTIME="$runtime" bash "$standalone_hook_dir/pre-commit-guard.sh" 2>&1)"
standalone_precommit_status=$?
set -e
assert_contains "status=$standalone_precommit_status" "status=1" "standalone pre-commit honors explicit VIBEGUARD_RUNTIME"
assert_contains "$standalone_precommit_output" "U16_BASELINE_BLOCK" "standalone pre-commit still prints U-16 evidence"

repo="$(make_repo ci)"
write_lines "$repo/src/lib.rs" 10
commit_all "$repo" "base"
base_ref="$(git -C "$repo" rev-parse HEAD)"
write_lines "$repo/src/new_big.rs" 801
commit_all "$repo" "big import"
set +e
ci_output="$(VIBEGUARD_U16_REPO_DIR="$repo" VIBEGUARD_RUNTIME="$runtime" bash "$REPO_DIR/scripts/ci/validate-u16-baseline.sh" "$base_ref" HEAD 2>&1)"
ci_status=$?
set -e
assert_contains "status=$ci_status" "status=1" "CI baseline check blocks oversized import"
assert_contains "$ci_output" "new_oversized" "CI baseline check names block reason"

hook_test_finish

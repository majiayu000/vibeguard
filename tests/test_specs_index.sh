#!/usr/bin/env bash
# VibeGuard specs-index sync regression tests
#
# Usage: bash tests/test_specs_index.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATOR="$REPO_DIR/scripts/ci/validate-specs-index.sh"

PASS=0
FAIL=0
TOTAL=0
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header(){ printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

assert_exit() {
  local desc="$1" expected="$2"
  shift 2
  TOTAL=$((TOTAL + 1))
  local actual=0
  "$@" >/dev/null 2>&1 || actual=$?
  if [[ "$actual" -eq "$expected" ]]; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected exit $expected, got $actual)"
    FAIL=$((FAIL + 1))
  fi
}

assert_stderr_contains() {
  local desc="$1" needle="$2"
  shift 2
  TOTAL=$((TOTAL + 1))
  local stderr_out
  stderr_out="$("$@" 2>&1 >/dev/null || true)"
  if [[ "$stderr_out" == *"$needle"* ]]; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (stderr missing: $needle)"
    FAIL=$((FAIL + 1))
  fi
}

make_fixture() {
  local name="$1"
  local dir="$TMP_DIR/$name"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

header "specs-index validator"

# In-sync fixture: one dir, one matching row.
SYNCED="$(make_fixture synced)"
mkdir -p "$SYNCED/GH100"
cat > "$SYNCED/README.md" <<'EOF'
| Spec | Status | Use it for |
|---|---|---|
| `GH100/` | Implemented reference | Fixture spec |
| `some-file.md` | Implemented reference | Non-directory rows are ignored |
EOF
assert_exit "in-sync specs dir passes" 0 bash "$VALIDATOR" "$SYNCED"

# Directory on disk missing from index.
UNINDEXED="$(make_fixture unindexed)"
mkdir -p "$UNINDEXED/GH100" "$UNINDEXED/GH101"
cat > "$UNINDEXED/README.md" <<'EOF'
| `GH100/` | Implemented reference | Fixture spec |
EOF
assert_exit "unindexed spec directory fails" 1 bash "$VALIDATOR" "$UNINDEXED"
assert_stderr_contains "unindexed failure names the directory" "docs/specs/GH101/" bash "$VALIDATOR" "$UNINDEXED"

# Index row without a directory on disk.
DANGLING="$(make_fixture dangling)"
mkdir -p "$DANGLING/GH100"
cat > "$DANGLING/README.md" <<'EOF'
| `GH100/` | Implemented reference | Fixture spec |
| `GH102/` | Implemented reference | Row without a directory |
EOF
assert_exit "index row without directory fails" 1 bash "$VALIDATOR" "$DANGLING"
assert_stderr_contains "dangling failure names the row" "GH102/" bash "$VALIDATOR" "$DANGLING"

# Missing README is an explicit error, not a silent pass.
EMPTY="$(make_fixture empty)"
mkdir -p "$EMPTY/GH100"
assert_exit "missing index file fails" 1 bash "$VALIDATOR" "$EMPTY"

# The live repo must be in sync.
assert_exit "live docs/specs index is in sync" 0 bash "$VALIDATOR"

printf '\n%d/%d passed\n' "$PASS" "$TOTAL"
[[ "$FAIL" -eq 0 ]]

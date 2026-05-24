#!/usr/bin/env bash
# VibeGuard worktree guard contract tests.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header(){ printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

assert_contains() {
  local output="$1" expected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$output" | grep -qF -- "$expected"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected to contain: $expected)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local output="$1" unexpected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if ! printf '%s' "$output" | grep -qF -- "$unexpected"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (unexpectedly contains: $unexpected)"
    FAIL=$((FAIL + 1))
  fi
}

finish() {
  printf '\nTotal: %s, Passed: %s, Failed: %s\n' "$TOTAL" "$PASS" "$FAIL"
  [[ "$FAIL" -eq 0 ]]
}

header "worktree-guard.sh list"

fixture_repo="${TMP_ROOT}/repo"
worktree_base="${TMP_ROOT}/repo.wt"
git init -q "$fixture_repo"
git -C "$fixture_repo" config user.email "test@example.com"
git -C "$fixture_repo" config user.name "Test User"
printf '%s\n' "# fixture" > "${fixture_repo}/README.md"
git -C "$fixture_repo" add README.md
git -C "$fixture_repo" commit -qm "init"

(
  cd "$fixture_repo"
  VIBEGUARD_WORKTREE_BASE="$worktree_base" bash "$REPO_DIR/scripts/worktree-guard.sh" create sample >/dev/null
)

list_output="$(
  cd "$fixture_repo"
  VIBEGUARD_WORKTREE_BASE="$worktree_base" bash "$REPO_DIR/scripts/worktree-guard.sh" list
)"

assert_contains "$list_output" "${worktree_base}/sample" "list shows worktree under configured base"
assert_not_contains "$list_output" "No active VibeGuard worktree" "list does not report empty when configured-base worktree exists"

finish

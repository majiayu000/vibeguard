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

mkdir -p "${fixture_repo}/.vibeguard/worktrees/ignored"

list_output="$(
  cd "$fixture_repo"
  VIBEGUARD_WORKTREE_BASE="$worktree_base" bash "$REPO_DIR/scripts/worktree-guard.sh" list
)"

assert_contains "$list_output" "${worktree_base}/sample" "list shows worktree under configured base"
assert_not_contains "$list_output" ".vibeguard/worktrees/ignored" "list ignores old in-repo worktree base"
assert_not_contains "$list_output" "No active VibeGuard worktree" "list does not report empty when configured-base worktree exists"

missing_status_output="$(
  cd "$fixture_repo"
  VIBEGUARD_WORKTREE_BASE="$worktree_base" bash "$REPO_DIR/scripts/worktree-guard.sh" status ignored 2>&1 || true
)"

assert_contains "$missing_status_output" "Error: worktree does not exist:" "status errors for old in-repo worktree base"
assert_contains "$missing_status_output" "repo.wt/ignored" "status resolves missing worktree against configured base"

header "worktree-guard.sh relative base"

relative_base="../relative.wt"
relative_base_abs="$(cd "$TMP_ROOT" && pwd -P)/relative.wt"
mkdir -p "${fixture_repo}/subdir"

(
  cd "$fixture_repo"
  VIBEGUARD_WORKTREE_BASE="$relative_base" bash "$REPO_DIR/scripts/worktree-guard.sh" create relative >/dev/null
)

relative_list_output="$(
  cd "${fixture_repo}/subdir"
  VIBEGUARD_WORKTREE_BASE="$relative_base" bash "$REPO_DIR/scripts/worktree-guard.sh" list
)"
relative_status_output="$(
  cd "${fixture_repo}/subdir"
  VIBEGUARD_WORKTREE_BASE="$relative_base" bash "$REPO_DIR/scripts/worktree-guard.sh" status relative
)"

assert_contains "$relative_list_output" "${relative_base_abs}/relative" "list resolves relative base against repo root"
assert_contains "$relative_status_output" "Path: ${relative_base_abs}/relative" "status resolves relative base against repo root"

finish

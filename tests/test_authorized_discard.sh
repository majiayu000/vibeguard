#!/usr/bin/env bash
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${REPO_DIR}/scripts/authorized-discard.py"
TMP_DIR=""

cleanup() {
  if [[ -n "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
}
trap cleanup EXIT

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red() { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

assert_contains() {
  local output="$1" expected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$output" | grep -qF -- "$expected"; then
    green "$desc"; PASS=$((PASS + 1))
  else
    red "$desc (expected to contain: $expected)"; FAIL=$((FAIL + 1))
  fi
}

assert_eq() {
  local actual="$1" expected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" == "$expected" ]]; then
    green "$desc"; PASS=$((PASS + 1))
  else
    red "$desc (expected '${expected}', got '${actual}')"; FAIL=$((FAIL + 1))
  fi
}

assert_cmd() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    green "$desc"; PASS=$((PASS + 1))
  else
    red "$desc (cmd: $*)"; FAIL=$((FAIL + 1))
  fi
}

assert_cmd_fail() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    red "$desc (unexpected success)"; FAIL=$((FAIL + 1))
  else
    green "$desc"; PASS=$((PASS + 1))
  fi
}

make_repo() {
  local name="$1"
  local repo="${TMP_DIR}/${name}"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.name "VibeGuard Test"
  git -C "$repo" config user.email "test@vibeguard.local"
  printf 'base\n' > "${repo}/tracked.txt"
  git -C "$repo" add tracked.txt
  git -C "$repo" commit -q -m "base"
  printf '%s\n' "$repo"
}

TMP_DIR="$(mktemp -d)"

header "tracked-only cleanup"
tracked_repo="$(make_repo tracked)"
printf 'changed\n' > "${tracked_repo}/tracked.txt"
tracked_plan="$(cd "$tracked_repo" && python3 "$SCRIPT" --plan)"
assert_contains "$tracked_plan" "Tracked paths to restore from HEAD:" "tracked plan names restore section"
assert_contains "$tracked_plan" "tracked.txt" "tracked plan enumerates modified file"
assert_eq "$(cat "${tracked_repo}/tracked.txt")" "changed" "plan mode does not change tracked file"
tracked_log="${TMP_DIR}/tracked-events.jsonl"
tracked_run="$(cd "$tracked_repo" && VIBEGUARD_LOG_FILE="$tracked_log" python3 "$SCRIPT" --confirm "discard listed changes")"
assert_contains "$tracked_run" "Authorized discard complete." "tracked cleanup completes"
assert_eq "$(cat "${tracked_repo}/tracked.txt")" "base" "tracked file restored to HEAD"
assert_eq "$(git -C "$tracked_repo" status --porcelain)" "" "tracked cleanup leaves clean status"
assert_contains "$(cat "$tracked_log")" '"hook": "authorized-discard"' "tracked cleanup writes audit log"

header "untracked-only cleanup"
untracked_repo="$(make_repo untracked)"
mkdir -p "${untracked_repo}/scratch"
printf 'temp\n' > "${untracked_repo}/scratch/tmp.txt"
untracked_plan="$(cd "$untracked_repo" && python3 "$SCRIPT" --plan)"
assert_contains "$untracked_plan" "scratch/tmp.txt" "untracked plan enumerates file"
untracked_run="$(cd "$untracked_repo" && VIBEGUARD_AUTHORIZED_DISCARD=discard-listed-changes python3 "$SCRIPT")"
assert_contains "$untracked_run" "Authorized discard complete." "env token authorizes untracked cleanup"
assert_cmd "untracked file removed" test ! -e "${untracked_repo}/scratch/tmp.txt"
assert_cmd "empty untracked parent pruned" test ! -d "${untracked_repo}/scratch"

header "untracked symlink cleanup"
symlink_repo="$(make_repo symlink)"
external_target="${TMP_DIR}/external-target"
mkdir -p "$external_target"
printf 'outside\n' > "${external_target}/kept.txt"
ln -s "${external_target}/kept.txt" "${symlink_repo}/external-link"
symlink_run="$(cd "$symlink_repo" && python3 "$SCRIPT" --confirm "discard listed changes")"
assert_contains "$symlink_run" "Authorized discard complete." "external symlink cleanup completes"
assert_cmd "external symlink entry removed" test ! -e "${symlink_repo}/external-link"
assert_cmd "external symlink target preserved" test -e "${external_target}/kept.txt"

header "mixed tracked and untracked cleanup"
mixed_repo="$(make_repo mixed)"
printf 'changed\n' > "${mixed_repo}/tracked.txt"
printf 'new\n' > "${mixed_repo}/new.txt"
mixed_run="$(cd "$mixed_repo" && python3 "$SCRIPT" --confirm "discard listed changes")"
assert_contains "$mixed_run" "Authorized discard complete." "mixed cleanup completes"
assert_eq "$(cat "${mixed_repo}/tracked.txt")" "base" "mixed cleanup restores tracked file"
assert_cmd "mixed cleanup deletes untracked file" test ! -e "${mixed_repo}/new.txt"
assert_eq "$(git -C "$mixed_repo" status --porcelain)" "" "mixed cleanup leaves clean status"

header "ignored file handling"
ignored_repo="$(make_repo ignored)"
printf '.env\nignored.txt\n' > "${ignored_repo}/.gitignore"
git -C "$ignored_repo" add .gitignore
git -C "$ignored_repo" commit -q -m "ignore fixtures"
printf 'SECRET=1\n' > "${ignored_repo}/.env"
printf 'cache\n' > "${ignored_repo}/ignored.txt"
ignored_plan="$(cd "$ignored_repo" && python3 "$SCRIPT" --plan)"
assert_contains "$ignored_plan" "Ignored paths not touched:" "default plan reports ignored paths as skipped"
assert_contains "$ignored_plan" ".env" "default plan names ignored secret-like file"
assert_cmd "default cleanup keeps ignored secret-like file" bash -c "cd '$ignored_repo' && python3 '$SCRIPT' --confirm 'discard listed changes' >/dev/null && test -e .env"
ignored_refuse="$(cd "$ignored_repo" && python3 "$SCRIPT" --include-ignored --confirm "discard listed changes" 2>&1)"
ignored_refuse_rc=$?
assert_eq "$ignored_refuse_rc" "4" "ignored secret-like cleanup needs separate confirmation"
assert_contains "$ignored_refuse" "Refusing ignored secret-like paths" "ignored refusal explains blocker"
assert_cmd "refusal keeps ignored non-secret file" test -e "${ignored_repo}/ignored.txt"
assert_cmd "refusal keeps ignored secret-like file" test -e "${ignored_repo}/.env"
ignored_run="$(cd "$ignored_repo" && python3 "$SCRIPT" --include-ignored --confirm "discard listed changes" --confirm-ignored "discard ignored secret-like files")"
assert_contains "$ignored_run" "Authorized discard complete." "second confirmation allows ignored cleanup"
assert_cmd "ignored non-secret file removed" test ! -e "${ignored_repo}/ignored.txt"
assert_cmd "ignored secret-like file removed" test ! -e "${ignored_repo}/.env"

header "outside repository"
outside_dir="${TMP_DIR}/outside"
mkdir -p "$outside_dir"
outside_out="$(cd "$outside_dir" && python3 "$SCRIPT" --plan 2>&1)"
outside_rc=$?
assert_eq "$outside_rc" "2" "outside repo exits nonzero"
assert_contains "$outside_out" "not inside a Git work tree" "outside repo error is explicit"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

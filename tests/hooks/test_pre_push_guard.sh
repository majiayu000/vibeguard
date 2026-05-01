#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
hook_test_init

header "hooks/git/pre-push — force push interception"
# =========================================================

PREPUSH_SCRIPT="${REPO_DIR}/hooks/git/pre-push"

# helper: run pre-push with fake stdin refs
run_prepush() {
  echo "$1" | bash "$PREPUSH_SCRIPT"
}

ZEROS="0000000000000000000000000000000000000000"

#New branches (remote_sha all zeros) should be released
if run_prepush "refs/heads/feature abc123 refs/heads/feature $ZEROS" 2>/dev/null; then
  green "New remote branch release (remote_sha=0000)"
  PASS=$((PASS + 1))
else
  red "New remote branch release (remote_sha=0000)"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

# Deleting remote branches (local_sha all zeros) should be intercepted
# Format: <local-ref> <local-sha> <remote-ref> <remote-sha>
# When deleting, local-sha is all zeros, and local-ref is marked with (delete)
if ! run_prepush "refs/heads/feature $ZEROS refs/heads/feature abc123" 2>/dev/null; then
  green "Interception and deletion of remote branches (local_sha=0000)"
  PASS=$((PASS + 1))
else
  red "Interception and deletion of remote branches (local_sha=0000)"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

# Temporary git repository: Verify that non-fast-forward push is intercepted
# stdin format: <local-ref> <local-sha> <remote-ref> <remote-sha>
tmp_repo_push="$(mktemp -d)"
git -C "$tmp_repo_push" init -q
git -C "$tmp_repo_push" config user.email "test@vibeguard.test"
git -C "$tmp_repo_push" config user.name "VibeGuard Test"
git -C "$tmp_repo_push" commit --allow-empty -m "base"
BASE_SHA=$(git -C "$tmp_repo_push" rev-parse HEAD)
git -C "$tmp_repo_push" commit --allow-empty -m "local"
LOCAL_SHA=$(git -C "$tmp_repo_push" rev-parse HEAD)
git -C "$tmp_repo_push" reset --hard "$BASE_SHA" -q
git -C "$tmp_repo_push" commit --allow-empty -m "diverged"
REMOTE_SHA=$(git -C "$tmp_repo_push" rev-parse HEAD)

# LOCAL_SHA and REMOTE_SHA fork from BASE_SHA → non-fastforward → intercept
if ! (cd "$tmp_repo_push" && echo "refs/heads/main $LOCAL_SHA refs/heads/main $REMOTE_SHA" | bash "$PREPUSH_SCRIPT") 2>/dev/null; then
  green "Intercept non-fast forward push (force push)"
  PASS=$((PASS + 1))
else
  red "Intercept non-fast-forward push (force push)"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

# Normal fast forward push should be allowed: FF_SHA is the direct successor of REMOTE_SHA
git -C "$tmp_repo_push" checkout -q "$REMOTE_SHA"
git -C "$tmp_repo_push" commit --allow-empty -m "fast-forward"
FF_SHA=$(git -C "$tmp_repo_push" rev-parse HEAD)

if (cd "$tmp_repo_push" && echo "refs/heads/main $FF_SHA refs/heads/main $REMOTE_SHA" | bash "$PREPUSH_SCRIPT") 2>/dev/null; then
  green "Fast forward push release"
  PASS=$((PASS + 1))
else
  red "Fast forward push release"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

rm -rf "$tmp_repo_push"

# =========================================================

hook_test_finish

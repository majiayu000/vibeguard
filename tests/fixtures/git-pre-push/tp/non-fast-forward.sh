#!/bin/bash
#Create a forked git repository to simulate non-fast-forward push
tmp=$(mktemp -d)
# Note: There is no trap, the runner is responsible for cleaning up CWD
git -C "$tmp" init -q
git -C "$tmp" commit --allow-empty -m "base"
BASE_SHA=$(git -C "$tmp" rev-parse HEAD)
git -C "$tmp" commit --allow-empty -m "local"
LOCAL_SHA=$(git -C "$tmp" rev-parse HEAD)
git -C "$tmp" reset --hard "$BASE_SHA" -q
git -C "$tmp" commit --allow-empty -m "diverged"
REMOTE_SHA=$(git -C "$tmp" rev-parse HEAD)
# Output: CWD and stdin
echo "CWD=$tmp"
echo "STDIN=refs/heads/main $LOCAL_SHA refs/heads/main $REMOTE_SHA"
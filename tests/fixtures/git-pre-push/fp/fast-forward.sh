#!/bin/bash
#Create fast forward push scene
tmp=$(mktemp -d)
# Note: There is no trap, the runner is responsible for cleaning up CWD
git -C "$tmp" init -q
git -C "$tmp" commit --allow-empty -m "base"
BASE_SHA=$(git -C "$tmp" rev-parse HEAD)
git -C "$tmp" commit --allow-empty -m "diverged"
REMOTE_SHA=$(git -C "$tmp" rev-parse HEAD)
git -C "$tmp" checkout -q "$REMOTE_SHA"
git -C "$tmp" commit --allow-empty -m "fast-forward"
FF_SHA=$(git -C "$tmp" rev-parse HEAD)
echo "CWD=$tmp"
echo "STDIN=refs/heads/main $FF_SHA refs/heads/main $REMOTE_SHA"
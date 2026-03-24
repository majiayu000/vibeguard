#!/bin/bash
# 创建快进推送场景
tmp=$(mktemp -d)
# 注意：不设 trap，runner 负责清理 CWD
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
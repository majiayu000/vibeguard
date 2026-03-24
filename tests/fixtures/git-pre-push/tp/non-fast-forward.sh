#!/bin/bash
# 创建分叉的 git 仓库，模拟非快进推送
tmp=$(mktemp -d)
# 注意：不设 trap，runner 负责清理 CWD
git -C "$tmp" init -q
git -C "$tmp" commit --allow-empty -m "base"
BASE_SHA=$(git -C "$tmp" rev-parse HEAD)
git -C "$tmp" commit --allow-empty -m "local"
LOCAL_SHA=$(git -C "$tmp" rev-parse HEAD)
git -C "$tmp" reset --hard "$BASE_SHA" -q
git -C "$tmp" commit --allow-empty -m "diverged"
REMOTE_SHA=$(git -C "$tmp" rev-parse HEAD)
# 输出: CWD和stdin
echo "CWD=$tmp"
echo "STDIN=refs/heads/main $LOCAL_SHA refs/heads/main $REMOTE_SHA"
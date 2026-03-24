#!/bin/bash
# Setup: 创建含重复定义的临时 git 仓库
tmp=$(mktemp -d)
# 注意：不设 trap，runner 负责清理
git -C "$tmp" init -q
mkdir -p "$tmp/src/existing" "$tmp/src/new"
cat >"$tmp/src/existing/handler.py" <<'PYEOF'
def processOrder():
    return 1
PYEOF
printf '{"tool_input":{"file_path":"%s/src/new/new_handler.py","content":"def processOrder():\\n    return 2"}}' "$tmp"
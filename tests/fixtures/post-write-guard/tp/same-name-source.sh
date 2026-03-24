#!/bin/bash
# Setup: 创建含同名文件的临时 git 仓库
tmp=$(mktemp -d)
# 注意：不设 trap，runner 负责清理
git -C "$tmp" init -q
mkdir -p "$tmp/src/existing" "$tmp/src/new"
cat >"$tmp/src/existing/service.py" <<'PYEOF'
def existing_service():
    return True
PYEOF
printf '{"tool_input":{"file_path":"%s/src/new/service.py","content":"def create_service():\\n    return True"}}' "$tmp"
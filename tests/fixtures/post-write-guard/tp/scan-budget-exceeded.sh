#!/bin/bash
# Setup: 临时 git 仓库 + VG_SCAN_MAX_FILES=0 强制降级
tmp=$(mktemp -d)
# 注意：不设 trap，runner 负责清理
git -C "$tmp" init -q
mkdir -p "$tmp/src"
cat >"$tmp/src/existing.py" <<'PYEOF'
def keepExisting():
    return "ok"
PYEOF
printf 'ENV=VG_SCAN_MAX_FILES=0\n'
printf '{"tool_input":{"file_path":"%s/src/new_file.py","content":"def keepExisting():\\n    return \\"new\\""}}' "$tmp"
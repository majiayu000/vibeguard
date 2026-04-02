#!/bin/bash
# Setup: Temporary git repository + VG_SCAN_MAX_FILES=0 forced downgrade
tmp=$(mktemp -d)
# Note: There is no trap, the runner is responsible for cleaning
git -C "$tmp" init -q
mkdir -p "$tmp/src"
cat >"$tmp/src/existing.py" <<'PYEOF'
def keepExisting():
    return "ok"
PYEOF
printf 'ENV=VG_SCAN_MAX_FILES=0\n'
printf '{"tool_input":{"file_path":"%s/src/new_file.py","content":"def keepExisting():\\n    return \\"new\\""}}' "$tmp"
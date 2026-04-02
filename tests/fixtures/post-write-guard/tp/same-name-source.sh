#!/bin/bash
# Setup: Create a temporary git repository containing files with the same name
tmp=$(mktemp -d)
# Note: There is no trap, the runner is responsible for cleaning
git -C "$tmp" init -q
mkdir -p "$tmp/src/existing" "$tmp/src/new"
cat >"$tmp/src/existing/service.py" <<'PYEOF'
def existing_service():
    return True
PYEOF
printf '{"tool_input":{"file_path":"%s/src/new/service.py","content":"def create_service():\\n    return True"}}' "$tmp"
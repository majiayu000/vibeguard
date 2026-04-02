#!/bin/bash
# Setup: Create a temporary git repository with duplicate definitions
tmp=$(mktemp -d)
# Note: There is no trap, the runner is responsible for cleaning
git -C "$tmp" init -q
mkdir -p "$tmp/src/existing" "$tmp/src/new"
cat >"$tmp/src/existing/handler.py" <<'PYEOF'
def processOrder():
    return 1
PYEOF
printf '{"tool_input":{"file_path":"%s/src/new/new_handler.py","content":"def processOrder():\\n    return 2"}}' "$tmp"
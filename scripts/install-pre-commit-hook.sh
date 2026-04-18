#!/usr/bin/env bash
# Install the local contract gate as a git pre-commit hook.
# Backs up any existing hook before overwriting.
#
# Usage:
#   bash scripts/install-pre-commit-hook.sh

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK_DIR="$REPO_ROOT/.git/hooks"
HOOK_FILE="$HOOK_DIR/pre-commit"

if [[ ! -d "$HOOK_DIR" ]]; then
  echo "Error: .git/hooks directory not found. Are you inside a git repository?" >&2
  exit 1
fi

# Back up any existing hook
if [[ -f "$HOOK_FILE" ]]; then
  BACKUP="$HOOK_FILE.bak.$(date +%s)"
  cp "$HOOK_FILE" "$BACKUP"
  echo "Existing hook backed up to: $BACKUP"
fi

cat > "$HOOK_FILE" <<EOF
#!/usr/bin/env bash
exec bash "\${REPO_ROOT}/scripts/local-contract-check.sh"
EOF

# Inject REPO_ROOT resolution into the hook so it works from any working dir
cat > "$HOOK_FILE" <<'EOF'
#!/usr/bin/env bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
exec bash "${REPO_ROOT}/scripts/local-contract-check.sh"
EOF

chmod +x "$HOOK_FILE"

echo "Installed pre-commit hook at: $HOOK_FILE"
echo "Runs on every 'git commit'. Use --quick to skip the freshness check:"
echo "  QUICK=1 git commit   # not supported via env — edit hook to pass --quick if needed"
echo ""
echo "To use --quick mode, edit $HOOK_FILE and change the exec line to:"
echo "  exec bash \"\${REPO_ROOT}/scripts/local-contract-check.sh\" --quick"

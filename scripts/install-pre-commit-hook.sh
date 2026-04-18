#!/usr/bin/env bash
# Install the local contract gate as a git pre-commit hook.
# Backs up any existing hook before overwriting.
#
# Usage:
#   bash scripts/install-pre-commit-hook.sh

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
# Works for regular repos, worktrees, and submodules
HOOK_DIR="$(git rev-parse --git-path hooks)"
HOOK_FILE="$HOOK_DIR/pre-commit"

if [[ ! -d "$HOOK_DIR" ]]; then
  echo "Error: hooks directory not found at $HOOK_DIR. Are you inside a git repository?" >&2
  exit 1
fi

if [[ -f "$HOOK_FILE" ]]; then
  if grep -qF "local-contract-check.sh" "$HOOK_FILE"; then
    echo "Contract gate already present in $HOOK_FILE — nothing to do."
    exit 0
  fi

  BACKUP="$HOOK_FILE.bak.$(date +%s)"
  cp "$HOOK_FILE" "$BACKUP"
  echo "Existing hook backed up to: $BACKUP"

  # Chain: append the contract gate so the existing hook's guards are preserved
  printf '\n# Contract gate (chained by install-pre-commit-hook.sh)\n__vg_root="$(git rev-parse --show-toplevel)"\nbash "${__vg_root}/scripts/local-contract-check.sh"\n' >> "$HOOK_FILE"
  echo "Contract gate appended to existing hook at: $HOOK_FILE"
else
  cat > "$HOOK_FILE" <<'EOF'
#!/usr/bin/env bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
exec bash "${REPO_ROOT}/scripts/local-contract-check.sh"
EOF
  chmod +x "$HOOK_FILE"
  echo "Installed pre-commit hook at: $HOOK_FILE"
fi

echo "Runs on every 'git commit'."
echo "To use --quick mode, edit $HOOK_FILE and change the exec line (or appended call) to pass --quick."

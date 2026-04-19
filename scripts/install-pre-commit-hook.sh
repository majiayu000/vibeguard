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
# Stable path for the original hook so the wrapper can call it
PREV_HOOK="$HOOK_DIR/pre-commit.vibeguard-prev"

if [[ ! -d "$HOOK_DIR" ]]; then
  echo "Error: hooks directory not found at $HOOK_DIR. Are you inside a git repository?" >&2
  exit 1
fi

# -L covers symlinks that exist without a backing regular file entry
if [[ -L "$HOOK_FILE" ]] || [[ -f "$HOOK_FILE" ]]; then
  if grep -qF "local-contract-check.sh" "$HOOK_FILE"; then
    echo "Contract gate already present in $HOOK_FILE — nothing to do."
    exit 0
  fi

  BACKUP="$HOOK_FILE.bak.$(date +%s)"
  cp "$HOOK_FILE" "$BACKUP"   # cp follows symlinks; backup always gets real content
  echo "Existing hook backed up to: $BACKUP"

  # Save the original content to a stable path the wrapper can call.
  # cp follows the symlink here, so PREV_HOOK is always a regular file.
  cp "$HOOK_FILE" "$PREV_HOOK"
  chmod +x "$PREV_HOOK"

  # Break any symlink so the next write creates a new regular file scoped to this
  # repo only.  Without this, writing to $HOOK_FILE would follow the symlink and
  # mutate the shared target (e.g. ~/.vibeguard/hooks/pre-commit-guard.sh) used by
  # every other repository on the machine.
  [[ -L "$HOOK_FILE" ]] && rm "$HOOK_FILE"

  # Write a wrapper that calls the original hook as a subprocess (bash, not exec).
  # Calling with exec would make everything after the exec line unreachable, so the
  # contract gate would silently never run on repos whose existing hook ends with
  # `exec bash <vibeguard-guard>`.
  cat > "$HOOK_FILE" <<HOOKEOF
#!/usr/bin/env bash
# Chain: previous hook runs as subprocess so exec-terminated hooks don't skip the gate
bash "${PREV_HOOK}" "\$@"
_prev_exit=\$?
# Contract gate (chained by install-pre-commit-hook.sh)
__vg_root="\$(git rev-parse --show-toplevel)"
bash "\${__vg_root}/scripts/local-contract-check.sh"
_gate_exit=\$?
exit \$(( _prev_exit != 0 ? _prev_exit : _gate_exit ))
HOOKEOF
  chmod +x "$HOOK_FILE"
  echo "Contract gate chained to existing hook at: $HOOK_FILE"
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

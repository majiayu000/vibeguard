#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "VibeGuard Codex Doctor"
echo "======================"
echo
echo "Mode: read-only diagnostics. This script reports Codex protection state; hooks and guards remain the enforcement layer."
echo

bash "${REPO_DIR}/setup.sh" --codex-status

cat <<'EOF'

Defense boundary
----------------
- Enforced in Codex: Bash/apply_patch PreToolUse, PermissionRequest, PostToolUse, and Stop hooks.
- Not native in Codex: Read/Glob/Grep hooks, so read/search behavior cannot be intercepted directly.
- Doctor role: summarize installation, hook semantics, capability gaps, latest event, and repair command.
- Guard role: block or warn during real tool execution. Do not move enforcement into this doctor.
EOF

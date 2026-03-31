#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
source "${SCRIPT_DIR}/../lib/install-state.sh"
source "${SCRIPT_DIR}/targets/claude-home.sh"
source "${SCRIPT_DIR}/targets/codex-home.sh"

echo "Cleaning VibeGuard installation..."

clean_claude_home_installation
clean_codex_home_installation

# Unload scheduled GC
PLIST_DEST="${HOME}/Library/LaunchAgents/com.vibeguard.gc.plist"
if [[ -f "${PLIST_DEST}" ]]; then
  launchctl bootout "gui/$(id -u)/com.vibeguard.gc" 2>/dev/null || true
  rm -f "${PLIST_DEST}"
  yellow "Removed scheduled GC (com.vibeguard.gc)"
fi

# Unload scheduled GC (Linux systemd)
if [[ "$(uname)" == "Linux" ]] && command -v systemctl &>/dev/null; then
  systemctl --user stop vibeguard-gc.timer 2>/dev/null || true
  systemctl --user disable vibeguard-gc.timer 2>/dev/null || true
  rm -f "${HOME}/.config/systemd/user/vibeguard-gc.service" \
        "${HOME}/.config/systemd/user/vibeguard-gc.timer"
  systemctl --user daemon-reload 2>/dev/null || true
  yellow "Removed scheduled GC (vibeguard-gc.timer)"
fi

# Remove install state
state_clean
yellow "Removed install state"

green "VibeGuard cleaned."

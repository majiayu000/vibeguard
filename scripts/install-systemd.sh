#!/usr/bin/env bash
# scripts/install-systemd.sh
# Install VibeGuard systemd user units on Linux.
#
# Usage:
#   bash scripts/install-systemd.sh              # install and enable
#   bash scripts/install-systemd.sh --remove     # disable and remove units
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

UNIT_DIR="${HOME}/.config/systemd/user"
SERVICE_SRC="${SCRIPT_DIR}/systemd/vibeguard-gc.service"
TIMER_SRC="${SCRIPT_DIR}/systemd/vibeguard-gc.timer"
SERVICE_DEST="${UNIT_DIR}/vibeguard-gc.service"
TIMER_DEST="${UNIT_DIR}/vibeguard-gc.timer"

red()    { echo -e "\033[31m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }

# --- Guards ---
if [[ "$(uname)" != "Linux" ]]; then
  red "ERROR: This script is for Linux only. Use the launchd plist on macOS."
  exit 1
fi

if ! command -v systemctl &>/dev/null; then
  red "ERROR: systemctl not found. Is systemd running?"
  exit 1
fi

# --- Remove mode ---
if [[ "${1:-}" == "--remove" ]]; then
  echo "Removing VibeGuard systemd units..."
  systemctl --user stop  vibeguard-gc.timer  2>/dev/null || true
  systemctl --user disable vibeguard-gc.timer 2>/dev/null || true
  rm -f "${SERVICE_DEST}" "${TIMER_DEST}"
  systemctl --user daemon-reload 2>/dev/null || true
  green "VibeGuard systemd units removed."
  exit 0
fi

# --- Install mode ---
echo "Installing VibeGuard systemd user units..."

if [[ ! -f "${SERVICE_SRC}" ]] || [[ ! -f "${TIMER_SRC}" ]]; then
  red "ERROR: Unit templates not found in ${SCRIPT_DIR}/systemd/"
  exit 1
fi

mkdir -p "${UNIT_DIR}"

# Substitute placeholders and write unit files
sed -e "s|__VIBEGUARD_DIR__|${REPO_DIR}|g" \
    -e "s|__HOME__|${HOME}|g" \
    "${SERVICE_SRC}" > "${SERVICE_DEST}"

sed -e "s|__VIBEGUARD_DIR__|${REPO_DIR}|g" \
    -e "s|__HOME__|${HOME}|g" \
    "${TIMER_SRC}" > "${TIMER_DEST}"

green "  Unit files written to ${UNIT_DIR}/"

# Make GC script executable
chmod +x "${REPO_DIR}/scripts/gc-scheduled.sh"

# Reload and enable
systemctl --user daemon-reload

if systemctl --user enable --now vibeguard-gc.timer 2>/dev/null; then
  green "  vibeguard-gc.timer enabled and started (every Sunday 3:00 AM)"
else
  yellow "  Timer installed but could not be started automatically."
  yellow "  Run manually: systemctl --user enable --now vibeguard-gc.timer"
fi

# Show timer status
echo
systemctl --user list-timers vibeguard-gc.timer --no-pager 2>/dev/null || true

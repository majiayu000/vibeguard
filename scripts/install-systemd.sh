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
REPO_DIR="${VIBEGUARD_REPO_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

UNIT_DIR="${HOME}/.config/systemd/user"
SERVICE_SRC="${SCRIPT_DIR}/systemd/vibeguard-gc.service"
TIMER_SRC="${SCRIPT_DIR}/systemd/vibeguard-gc.timer"
SERVICE_DEST="${UNIT_DIR}/vibeguard-gc.service"
TIMER_DEST="${UNIT_DIR}/vibeguard-gc.timer"
SCHEDULER_RECEIPT="${HOME}/.vibeguard/scheduler-ownership"
LAUNCHD_DEST="${HOME}/Library/LaunchAgents/com.vibeguard.gc.plist"

red()    { echo -e "\033[31m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }

scheduler_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

scheduler_receipt_value() {
  local key="$1"
  awk -F= -v key="${key}" '
    $1 == key { count += 1; value = $2 }
    END {
      if (count == 1 && value != "") print value
      else exit 1
    }
  ' "${SCHEDULER_RECEIPT}"
}

if [[ "${REPO_DIR}" != /* || ! -d "${REPO_DIR}" ]]; then
  red "ERROR: VIBEGUARD_REPO_DIR must name an absolute VibeGuard directory."
  exit 1
fi

# --- Guards ---
if [[ "$(uname)" != "Linux" ]]; then
  red "ERROR: This script is for Linux only. Use the launchd plist on macOS."
  exit 1
fi

if ! command -v systemctl &>/dev/null; then
  red "ERROR: systemctl not found. Is systemd running?"
  exit 1
fi

if [[ -e "${SCHEDULER_RECEIPT}" || -L "${SCHEDULER_RECEIPT}" ]]; then
  if [[ -L "${SCHEDULER_RECEIPT}" || ! -f "${SCHEDULER_RECEIPT}" ]]; then
    red "ERROR: scheduler ownership receipt must be absent or a regular non-symlink file: ${SCHEDULER_RECEIPT}"
    exit 1
  fi
  if awk 'NR == 2 && $0 == "kind=launchd" { found = 1 } END { exit(found ? 0 : 1) }' \
    "${SCHEDULER_RECEIPT}"; then
    red "ERROR: scheduler ownership receipt kind launchd does not match Linux systemd scheduler."
    exit 1
  fi
  if grep -qFx "phase=cleaning" "${SCHEDULER_RECEIPT}"; then
    red "ERROR: scheduler ownership receipt is in cleaning phase; rerun setup --clean before installing."
    exit 1
  fi
fi
if [[ -e "${LAUNCHD_DEST}" || -L "${LAUNCHD_DEST}" ]]; then
  red "ERROR: wrong-platform launchd scheduler file exists; refusing to create a systemd scheduler."
  exit 1
fi

# --- Remove mode ---
if [[ "${1:-}" == "--remove" ]]; then
  REMOVE_RECEIPT=0
  if [[ -f "${SCHEDULER_RECEIPT}" && ! -L "${SCHEDULER_RECEIPT}" ]]; then
    receipt_kind="$(scheduler_receipt_value kind)" || {
      red "ERROR: scheduler ownership receipt is invalid; preserving scheduler state."
      exit 1
    }
    [[ "${receipt_kind}" == "systemd" ]] || {
      red "ERROR: scheduler ownership receipt kind ${receipt_kind} does not match Linux systemd scheduler."
      exit 1
    }
    receipt_phase="$(scheduler_receipt_value phase 2>/dev/null || printf 'managed')"
    [[ "${receipt_phase}" == "managed" ]] || {
      red "ERROR: scheduler ownership receipt is in cleaning phase; rerun setup --clean."
      exit 1
    }
    service_sha="$(scheduler_receipt_value service_sha256)"
    timer_sha="$(scheduler_receipt_value timer_sha256)"
    [[ "${service_sha}" =~ ^[0-9a-f]{64}$ && "${timer_sha}" =~ ^[0-9a-f]{64}$ ]] || {
      red "ERROR: scheduler ownership receipt hashes are invalid; preserving scheduler state."
      exit 1
    }
    for unit_path in "${SERVICE_DEST}" "${TIMER_DEST}"; do
      if [[ -L "${unit_path}" || (-e "${unit_path}" && ! -f "${unit_path}") ]]; then
        red "ERROR: systemd unit must be a regular file or absent; preserving scheduler state: ${unit_path}"
        exit 1
      fi
    done
    if [[ -e "${SERVICE_DEST}" ]] \
      && [[ "$(scheduler_sha256_file "${SERVICE_DEST}")" != "${service_sha}" ]]; then
      red "ERROR: systemd service changed after ownership was recorded; preserving scheduler state."
      exit 1
    fi
    if [[ -e "${TIMER_DEST}" ]] \
      && [[ "$(scheduler_sha256_file "${TIMER_DEST}")" != "${timer_sha}" ]]; then
      red "ERROR: systemd timer changed after ownership was recorded; preserving scheduler state."
      exit 1
    fi
    REMOVE_RECEIPT=1
  fi
  echo "Removing VibeGuard systemd units..."
  systemctl --user stop  vibeguard-gc.timer  2>/dev/null || true
  systemctl --user disable vibeguard-gc.timer 2>/dev/null || true
  rm -f "${SERVICE_DEST}" "${TIMER_DEST}"
  if [[ "${REMOVE_RECEIPT}" == "1" ]]; then
    rm -f "${SCHEDULER_RECEIPT}"
  fi
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

for unit_dest in "${SERVICE_DEST}" "${TIMER_DEST}"; do
  if [[ -L "${unit_dest}" || (-e "${unit_dest}" && ! -f "${unit_dest}") ]]; then
    red "ERROR: systemd unit destination must be a regular file or absent: ${unit_dest}"
    exit 1
  fi
done

# Escape values for use as sed replacement strings (|, &, and \ are metacharacters)
_escape_sed() { printf '%s\n' "$1" | sed 's/[\\&|]/\\&/g'; }
ESCAPED_REPO_DIR="$(_escape_sed "${REPO_DIR}")"
ESCAPED_HOME="$(_escape_sed "${HOME}")"

# Substitute placeholders and write unit files
sed -e "s|__VIBEGUARD_DIR__|${ESCAPED_REPO_DIR}|g" \
    -e "s|__HOME__|${ESCAPED_HOME}|g" \
    "${SERVICE_SRC}" > "${SERVICE_DEST}"

sed -e "s|__VIBEGUARD_DIR__|${ESCAPED_REPO_DIR}|g" \
    -e "s|__HOME__|${ESCAPED_HOME}|g" \
    "${TIMER_SRC}" > "${TIMER_DEST}"

green "  Unit files written to ${UNIT_DIR}/"

# Make GC script executable
chmod +x "${REPO_DIR}/scripts/gc/gc-scheduled.sh"

# Reload and enable
systemctl --user daemon-reload

if systemctl --user enable --now vibeguard-gc.timer 2>/dev/null; then
  green "  vibeguard-gc.timer enabled and started (every Sunday 3:00 AM)"
else
  red "ERROR: Timer installed but could not be started automatically."
  red "Run manually: systemctl --user enable --now vibeguard-gc.timer"
  exit 1
fi

# Show timer status
echo
systemctl --user list-timers vibeguard-gc.timer --no-pager 2>/dev/null || true

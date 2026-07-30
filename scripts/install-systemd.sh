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

scheduler_receipt_parse() {
  awk -F= '
    NR == 1 && $1 == "schema" && $2 == "1" { next }
    NR == 2 && $1 == "kind" && ($2 == "launchd" || $2 == "systemd") { kind = $2; next }
    NR == 3 && $1 == "phase" && ($2 == "managed" || $2 == "cleaning") {
      phase = $2
      declared_phase = 1
      next
    }
    NR == 3 && ((kind == "launchd" && $1 == "plist_sha256") || (kind == "systemd" && $1 == "service_sha256")) && $2 ~ /^[0-9a-f]{64}$/ {
      phase = "managed"
      first = $2
      next
    }
    NR == 4 && declared_phase && ((kind == "launchd" && $1 == "plist_sha256") || (kind == "systemd" && $1 == "service_sha256")) && $2 ~ /^[0-9a-f]{64}$/ {
      first = $2
      next
    }
    NR == 4 && !declared_phase && kind == "systemd" && $1 == "timer_sha256" && $2 ~ /^[0-9a-f]{64}$/ {
      second = $2
      next
    }
    NR == 5 && declared_phase && kind == "systemd" && $1 == "timer_sha256" && $2 ~ /^[0-9a-f]{64}$/ {
      second = $2
      next
    }
    { bad = 1 }
    END {
      launchd_ok = kind == "launchd" && first != "" && second == "" && ((!declared_phase && NR == 3) || (declared_phase && NR == 4))
      systemd_ok = kind == "systemd" && first != "" && second != "" && ((!declared_phase && NR == 4) || (declared_phase && NR == 5))
      if (!bad && phase != "" && (launchd_ok || systemd_ok)) {
        print kind "\t" phase "\t" first "\t" second
        exit 0
      }
      exit 1
    }
  ' "$1"
}

scheduler_verify_deactivated() {
  local stop_rc=0 active_state="" active_rc=0
  local disable_rc=0 enabled_state="" enabled_rc=0
  systemctl --user stop vibeguard-gc.timer >/dev/null 2>&1 || stop_rc=$?
  active_state="$(LC_ALL=C systemctl --user is-active vibeguard-gc.timer 2>/dev/null)" \
    || active_rc=$?
  case "${active_state}" in
    inactive|failed|unknown) ;;
    *)
      red "ERROR: vibeguard-gc.timer is not proven inactive (stop_rc=${stop_rc}, state=${active_state:-empty}, rc=${active_rc}); preserving units and receipt."
      return 1
      ;;
  esac
  systemctl --user disable vibeguard-gc.timer >/dev/null 2>&1 || disable_rc=$?
  enabled_state="$(LC_ALL=C systemctl --user is-enabled vibeguard-gc.timer 2>/dev/null)" \
    || enabled_rc=$?
  case "${enabled_state}" in
    disabled|masked|not-found) ;;
    *)
      red "ERROR: vibeguard-gc.timer is not proven disabled (disable_rc=${disable_rc}, state=${enabled_state:-empty}, rc=${enabled_rc}); preserving units and receipt."
      return 1
      ;;
  esac
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

SCHEDULER_RECEIPT_PARSED=""
if [[ -e "${SCHEDULER_RECEIPT}" || -L "${SCHEDULER_RECEIPT}" ]]; then
  if [[ -L "${SCHEDULER_RECEIPT}" || ! -f "${SCHEDULER_RECEIPT}" ]]; then
    red "ERROR: scheduler ownership receipt must be absent or a regular non-symlink file: ${SCHEDULER_RECEIPT}"
    exit 1
  fi
  if SCHEDULER_RECEIPT_PARSED="$(scheduler_receipt_parse "${SCHEDULER_RECEIPT}" 2>/dev/null)"; then
    IFS=$'\t' read -r receipt_kind receipt_phase _ \
      <<< "${SCHEDULER_RECEIPT_PARSED}"
    if [[ "${receipt_kind}" != "systemd" ]]; then
      red "ERROR: scheduler ownership receipt kind ${receipt_kind} does not match Linux systemd scheduler."
      exit 1
    fi
    if [[ "${receipt_phase}" != "managed" ]]; then
      red "ERROR: scheduler ownership receipt is in cleaning phase; rerun setup --clean before installing."
      exit 1
    fi
  elif [[ "${1:-}" == "--remove" \
    || -e "${SERVICE_DEST}" || -L "${SERVICE_DEST}" \
    || -e "${TIMER_DEST}" || -L "${TIMER_DEST}" ]]; then
    red "ERROR: scheduler ownership receipt is invalid; preserving scheduler state."
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
    IFS=$'\t' read -r _ _ service_sha timer_sha \
      <<< "${SCHEDULER_RECEIPT_PARSED}"
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
  scheduler_verify_deactivated || exit 1
  REMOVE_BACKUP_DIR=""
  if [[ -e "${SERVICE_DEST}" || -e "${TIMER_DEST}" ]]; then
    REMOVE_BACKUP_DIR="$(mktemp -d "${UNIT_DIR}/.vibeguard-systemd-remove.XXXXXX")"
    if [[ -e "${SERVICE_DEST}" ]] \
      && ! mv -- "${SERVICE_DEST}" "${REMOVE_BACKUP_DIR}/vibeguard-gc.service"; then
      rmdir "${REMOVE_BACKUP_DIR}" 2>/dev/null || true
      red "ERROR: failed to stage systemd service removal; preserved units and receipt."
      exit 1
    fi
    if [[ -e "${TIMER_DEST}" ]] \
      && ! mv -- "${TIMER_DEST}" "${REMOVE_BACKUP_DIR}/vibeguard-gc.timer"; then
      restore_rc=0
      [[ ! -e "${REMOVE_BACKUP_DIR}/vibeguard-gc.service" ]] \
        || mv -- "${REMOVE_BACKUP_DIR}/vibeguard-gc.service" "${SERVICE_DEST}" \
        || restore_rc=$?
      rmdir "${REMOVE_BACKUP_DIR}" 2>/dev/null || true
      if [[ "${restore_rc}" -ne 0 ]]; then
        red "ERROR: failed to stage systemd timer removal and service restoration was incomplete; receipt preserved, inspect ${REMOVE_BACKUP_DIR}."
        exit 1
      fi
      red "ERROR: failed to stage systemd timer removal; restored units and preserved receipt."
      exit 1
    fi
  fi
  if ! systemctl --user daemon-reload >/dev/null 2>&1; then
    if [[ -n "${REMOVE_BACKUP_DIR}" ]]; then
      restore_rc=0
      [[ ! -e "${REMOVE_BACKUP_DIR}/vibeguard-gc.service" ]] \
        || mv -- "${REMOVE_BACKUP_DIR}/vibeguard-gc.service" "${SERVICE_DEST}" \
        || restore_rc=$?
      [[ ! -e "${REMOVE_BACKUP_DIR}/vibeguard-gc.timer" ]] \
        || mv -- "${REMOVE_BACKUP_DIR}/vibeguard-gc.timer" "${TIMER_DEST}" \
        || restore_rc=$?
      rmdir "${REMOVE_BACKUP_DIR}" 2>/dev/null || true
      if [[ "${restore_rc}" -ne 0 ]]; then
        red "ERROR: systemd daemon reload failed and unit restoration was incomplete; receipt preserved, inspect ${REMOVE_BACKUP_DIR}."
        exit 1
      fi
    fi
    red "ERROR: systemd daemon reload failed; restored units and preserved receipt."
    exit 1
  fi
  [[ -z "${REMOVE_BACKUP_DIR}" ]] || rm -rf -- "${REMOVE_BACKUP_DIR}"
  if [[ "${REMOVE_RECEIPT}" == "1" ]]; then
    rm -f "${SCHEDULER_RECEIPT}"
  fi
  green "VibeGuard systemd units removed."
  exit 0
fi

# --- Install mode ---
if [[ -n "${SCHEDULER_RECEIPT_PARSED}" ]]; then
  IFS=$'\t' read -r _ _ service_sha timer_sha \
    <<< "${SCHEDULER_RECEIPT_PARSED}"
  if [[ -L "${SERVICE_DEST}" || ! -f "${SERVICE_DEST}" \
    || -L "${TIMER_DEST}" || ! -f "${TIMER_DEST}" ]]; then
    red "ERROR: scheduler ownership receipt does not match current systemd files; preserving scheduler state."
    exit 1
  fi
  actual_service_sha="$(scheduler_sha256_file "${SERVICE_DEST}")" || {
    red "ERROR: failed to hash current systemd service; preserving scheduler state."
    exit 1
  }
  actual_timer_sha="$(scheduler_sha256_file "${TIMER_DEST}")" || {
    red "ERROR: failed to hash current systemd timer; preserving scheduler state."
    exit 1
  }
  if [[ "${actual_service_sha}" != "${service_sha}" \
    || "${actual_timer_sha}" != "${timer_sha}" ]]; then
    red "ERROR: scheduler ownership receipt does not match current systemd files; preserving scheduler state."
    exit 1
  fi
fi

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

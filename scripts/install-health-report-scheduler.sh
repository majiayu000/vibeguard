#!/usr/bin/env bash
# Install the opt-in weekly VibeGuard health report scheduler.
#
# Default mode is a dry-run plan. Use --install to modify launchd or crontab.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MODE="plan"
DAYS=30
SCOPE="global"
OUTPUT_DIR="${VIBEGUARD_HEALTH_REPORT_DIR:-${HOME}/.vibeguard/reports/health}"
LAUNCHD_LABEL="com.vibeguard.health-report"
PLIST_SRC="${SCRIPT_DIR}/setup/com.vibeguard.health-report.plist"
PLIST_DEST="${HOME}/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
CRON_MARKER_BEGIN="# VibeGuard health report scheduler start"
CRON_MARKER_END="# VibeGuard health report scheduler end"
CRON_FILE="${VIBEGUARD_HEALTH_REPORT_TEST_CRONTAB:-}"

usage() {
  cat <<'USAGE'
Usage: bash scripts/install-health-report-scheduler.sh [--install|--remove|--dry-run] [options]

Options:
  --install          Install the weekly launchd/cron scheduler
  --remove           Remove the installed scheduler
  --dry-run          Print the install plan without writing scheduler config
  --days N           Report window size in days (default: 30)
  --scope SCOPE      project or global (default: global)
  --output-dir PATH  Report output directory (default: ~/.vibeguard/reports/health)
  --repo-dir PATH    Override repo path for tests
  --help, -h         Show this help

Default behavior is --dry-run. No scheduler is installed unless --install is passed.
USAGE
}

test_uname() {
  if [[ -n "${VIBEGUARD_HEALTH_REPORT_TEST_UNAME:-}" ]]; then
    printf '%s\n' "${VIBEGUARD_HEALTH_REPORT_TEST_UNAME}"
  else
    uname
  fi
}

escape_sed() {
  printf '%s\n' "$1" | sed 's/[\\&|]/\\&/g'
}

escape_xml() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  printf '%s\n' "${value}"
}

escape_sed_xml() {
  escape_sed "$(escape_xml "$1")"
}

shell_quote() {
  local value="$1"
  printf "'%s'" "$(printf '%s' "${value}" | sed "s/'/'\\\\''/g")"
}

reject_multiline_value() {
  local name="$1"
  local value="$2"
  if [[ "${value}" == *$'\n'* || "${value}" == *$'\r'* ]]; then
    echo "ERROR: ${name} must not contain newlines" >&2
    exit 64
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) MODE="install"; shift ;;
    --remove) MODE="remove"; shift ;;
    --dry-run) MODE="plan"; shift ;;
    --days)
      [[ $# -lt 2 ]] && { echo "ERROR: --days requires a value" >&2; exit 64; }
      DAYS="$2"; shift 2 ;;
    --scope)
      [[ $# -lt 2 ]] && { echo "ERROR: --scope requires a value" >&2; exit 64; }
      SCOPE="$2"; shift 2 ;;
    --output-dir)
      [[ $# -lt 2 ]] && { echo "ERROR: --output-dir requires a value" >&2; exit 64; }
      OUTPUT_DIR="$2"; shift 2 ;;
    --repo-dir)
      [[ $# -lt 2 ]] && { echo "ERROR: --repo-dir requires a value" >&2; exit 64; }
      REPO_DIR="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 64 ;;
  esac
done

case "${SCOPE}" in
  project|global) ;;
  *) echo "ERROR: --scope must be project or global" >&2; exit 64 ;;
esac

if ! [[ "${DAYS}" =~ ^[0-9]+$ ]] || [[ "${DAYS}" -le 0 ]]; then
  echo "ERROR: --days must be a positive integer" >&2
  exit 64
fi

reject_multiline_value "--repo-dir" "${REPO_DIR}"
reject_multiline_value "--output-dir" "${OUTPUT_DIR}"
reject_multiline_value "HOME" "${HOME}"

SCHEDULE_CMD="/bin/bash $(shell_quote "${REPO_DIR}/scripts/health-report-scheduled.sh") --scheduled --days $(shell_quote "${DAYS}") --scope $(shell_quote "${SCOPE}") --output-dir $(shell_quote "${OUTPUT_DIR}")"

print_plan() {
  local os_name="$1"
  printf 'VibeGuard health report scheduler plan\n'
  printf 'Mode: %s\n' "${MODE}"
  printf 'OS: %s\n' "${os_name}"
  printf 'Schedule: weekly Monday 09:00\n'
  printf 'Reports: %s\n' "${OUTPUT_DIR}"
  printf 'Command: %s\n' "${SCHEDULE_CMD}"
  if [[ "${MODE}" != "install" ]]; then
    printf 'No scheduler installed. Re-run with --install to opt in.\n'
  fi
}

install_launchd() {
  [[ -f "${PLIST_SRC}" ]] || { echo "ERROR: missing launchd template: ${PLIST_SRC}" >&2; exit 1; }
  mkdir -p "$(dirname "${PLIST_DEST}")"
  sed -e "s|__VIBEGUARD_DIR__|$(escape_sed_xml "${REPO_DIR}")|g" \
      -e "s|__HOME__|$(escape_sed_xml "${HOME}")|g" \
      -e "s|__DAYS__|$(escape_sed_xml "${DAYS}")|g" \
      -e "s|__SCOPE__|$(escape_sed_xml "${SCOPE}")|g" \
      -e "s|__OUTPUT_DIR__|$(escape_sed_xml "${OUTPUT_DIR}")|g" \
      "${PLIST_SRC}" > "${PLIST_DEST}"
  chmod 600 "${PLIST_DEST}"
  if [[ "${VIBEGUARD_HEALTH_REPORT_TEST_SKIP_LAUNCHCTL:-0}" != "1" ]]; then
    launchctl bootout "gui/$(id -u)/${LAUNCHD_LABEL}" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "${PLIST_DEST}"
  fi
  printf 'Installed launchd scheduler: %s\n' "${PLIST_DEST}"
}

remove_launchd() {
  if [[ "${VIBEGUARD_HEALTH_REPORT_TEST_SKIP_LAUNCHCTL:-0}" != "1" ]]; then
    launchctl bootout "gui/$(id -u)/${LAUNCHD_LABEL}" 2>/dev/null || true
  fi
  rm -f "${PLIST_DEST}"
  printf 'Removed launchd scheduler: %s\n' "${PLIST_DEST}"
}

cron_read() {
  if [[ -n "${CRON_FILE}" ]]; then
    [[ -f "${CRON_FILE}" ]] && cat "${CRON_FILE}"
    return 0
  else
    crontab -l 2>/dev/null || true
  fi
}

cron_write() {
  if [[ -n "${CRON_FILE}" ]]; then
    mkdir -p "$(dirname "${CRON_FILE}")"
    cat > "${CRON_FILE}"
  else
    crontab -
  fi
}

install_cron() {
  local cron_tmp entry log_path
  cron_tmp="$(mktemp)"
  trap 'rm -f "${cron_tmp}"' RETURN
  cron_read | awk -v start="${CRON_MARKER_BEGIN}" -v end="${CRON_MARKER_END}" '
    $0 == start { skip = 1; next }
    $0 == end { skip = 0; next }
    skip != 1 { print }
  ' > "${cron_tmp}"
  log_path="${HOME}/.vibeguard/health-report-cron.log"
  entry="0 9 * * 1 ${SCHEDULE_CMD} >> $(shell_quote "${log_path}") 2>&1"
  {
    if [[ -s "${cron_tmp}" ]]; then
      cat "${cron_tmp}"
      printf '\n'
    fi
    printf '%s\n' "${CRON_MARKER_BEGIN}"
    printf '%s\n' "${entry}"
    printf '%s\n' "${CRON_MARKER_END}"
  } | cron_write
  printf 'Installed cron scheduler for weekly health report\n'
}

remove_cron() {
  cron_read | awk -v start="${CRON_MARKER_BEGIN}" -v end="${CRON_MARKER_END}" '
    $0 == start { skip = 1; next }
    $0 == end { skip = 0; next }
    skip != 1 { print }
  ' | cron_write
  printf 'Removed cron scheduler for weekly health report\n'
}

OS_NAME="$(test_uname)"
print_plan "${OS_NAME}"

case "${MODE}:${OS_NAME}" in
  plan:*) exit 0 ;;
  install:Darwin) install_launchd ;;
  remove:Darwin) remove_launchd ;;
  install:*) install_cron ;;
  remove:*) remove_cron ;;
esac

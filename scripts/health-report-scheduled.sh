#!/usr/bin/env bash
# VibeGuard scheduled health report wrapper.
#
# This script is safe to run manually. It writes one markdown or JSON report to
# ~/.vibeguard/reports/health by default and never installs a scheduler.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

DAYS=30
SCOPE="global"
FORMAT="markdown"
OUTPUT_DIR="${VIBEGUARD_HEALTH_REPORT_DIR:-${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}/reports/health}"
PROJECT=""
LOG_FILE=""
TRIAGE_FILE=""
SCORECARD_FILE=""
ADOPTIONS_FILE=""
REPORT_DATE="${VIBEGUARD_HEALTH_REPORT_DATE:-}"
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage: bash scripts/health-report-scheduled.sh [options]

Options:
  --dry-run              Print the report path and command without writing
  --scheduled            Accepted for launchd/cron callers; same behavior as default
  --days N               Window size in days (default: 30)
  --scope project|global Event log scope (default: global)
  --project REF          Project reference for observe
  --log-file PATH        Explicit event log path
  --triage-file PATH     Explicit triage JSONL path
  --scorecard-file PATH  Explicit scorecard JSON path
  --adoptions-file PATH  Explicit Learn adoption JSONL path
  --format markdown|json Output format (default: markdown)
  --output-dir PATH      Directory for report files
  --report-date DATE     Report date for deterministic tests (YYYY-MM-DD)
  --help, -h             Show this help

Default output:
  ~/.vibeguard/reports/health/YYYY-MM-DD.md
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --scheduled) shift ;;
    --days)
      [[ $# -lt 2 ]] && { echo "ERROR: --days requires a value" >&2; exit 64; }
      DAYS="$2"; shift 2 ;;
    --scope)
      [[ $# -lt 2 ]] && { echo "ERROR: --scope requires a value" >&2; exit 64; }
      SCOPE="$2"; shift 2 ;;
    --project)
      [[ $# -lt 2 ]] && { echo "ERROR: --project requires a value" >&2; exit 64; }
      PROJECT="$2"; shift 2 ;;
    --log-file)
      [[ $# -lt 2 ]] && { echo "ERROR: --log-file requires a value" >&2; exit 64; }
      LOG_FILE="$2"; shift 2 ;;
    --triage-file)
      [[ $# -lt 2 ]] && { echo "ERROR: --triage-file requires a value" >&2; exit 64; }
      TRIAGE_FILE="$2"; shift 2 ;;
    --scorecard-file)
      [[ $# -lt 2 ]] && { echo "ERROR: --scorecard-file requires a value" >&2; exit 64; }
      SCORECARD_FILE="$2"; shift 2 ;;
    --adoptions-file)
      [[ $# -lt 2 ]] && { echo "ERROR: --adoptions-file requires a value" >&2; exit 64; }
      ADOPTIONS_FILE="$2"; shift 2 ;;
    --format)
      [[ $# -lt 2 ]] && { echo "ERROR: --format requires a value" >&2; exit 64; }
      FORMAT="$2"; shift 2 ;;
    --output-dir)
      [[ $# -lt 2 ]] && { echo "ERROR: --output-dir requires a value" >&2; exit 64; }
      OUTPUT_DIR="$2"; shift 2 ;;
    --report-date)
      [[ $# -lt 2 ]] && { echo "ERROR: --report-date requires a value" >&2; exit 64; }
      REPORT_DATE="$2"; shift 2 ;;
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

case "${FORMAT}" in
  markdown) EXT="md" ;;
  json) EXT="json" ;;
  *) echo "ERROR: --format must be markdown or json" >&2; exit 64 ;;
esac

if ! [[ "${DAYS}" =~ ^[0-9]+$ ]] || [[ "${DAYS}" -le 0 ]]; then
  echo "ERROR: --days must be a positive integer" >&2
  exit 64
fi

if [[ -z "${REPORT_DATE}" ]]; then
  REPORT_DATE="$(date -u '+%Y-%m-%d')"
fi
if ! [[ "${REPORT_DATE}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "ERROR: --report-date must be YYYY-MM-DD" >&2
  exit 64
fi

OUTPUT_PATH="${OUTPUT_DIR}/${REPORT_DATE}.${EXT}"
CMD=(python3 "${SCRIPT_DIR}/health-report.py" --days "${DAYS}" --scope "${SCOPE}" --format "${FORMAT}" --output "${OUTPUT_PATH}")
[[ -z "${PROJECT}" ]] || CMD+=(--project "${PROJECT}")
[[ -z "${LOG_FILE}" ]] || CMD+=(--log-file "${LOG_FILE}")
[[ -z "${TRIAGE_FILE}" ]] || CMD+=(--triage-file "${TRIAGE_FILE}")
[[ -z "${SCORECARD_FILE}" ]] || CMD+=(--scorecard-file "${SCORECARD_FILE}")
[[ -z "${ADOPTIONS_FILE}" ]] || CMD+=(--adoptions-file "${ADOPTIONS_FILE}")

if [[ "${DRY_RUN}" == "1" ]]; then
  printf 'Health report scheduler dry run\n'
  printf 'Output: %s\n' "${OUTPUT_PATH}"
  printf 'Command:'
  printf ' %q' "${CMD[@]}"
  printf '\n'
  exit 0
fi

mkdir -p "${OUTPUT_DIR}"
"${CMD[@]}"

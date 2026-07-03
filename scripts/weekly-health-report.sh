#!/usr/bin/env bash
# VibeGuard weekly health report
# Aggregate observe metrics, precision feedback, and skill adoption evidence.
#
# Usage:
# bash scripts/weekly-health-report.sh
# bash scripts/weekly-health-report.sh --scope global 30
# bash scripts/weekly-health-report.sh --log-file /path/to/events.jsonl --json

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_DIR}/scripts/lib/runtime.sh"

usage() {
  echo "Usage: bash scripts/weekly-health-report.sh [--scope project|global] [--project PATH_OR_HASH] [--log-file PATH] [--triage-file PATH] [--scorecard-file PATH] [--rules-dir PATH] [--skills-dir PATH] [--json] [DAYS]"
}

DAYS="30"
PY_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope|--project|--log-file|--triage-file|--scorecard-file|--rules-dir|--skills-dir|--top|--fp-rate-threshold)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      PY_ARGS+=("$1" "$2")
      shift 2
      ;;
    --json)
      PY_ARGS+=("$1")
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      usage >&2
      exit 2
      ;;
    *)
      DAYS="$1"
      shift
      if [[ $# -gt 0 ]]; then
        usage >&2
        exit 2
      fi
      ;;
  esac
done

if ! [[ "${DAYS}" =~ ^[0-9]+$ ]] || [[ "${DAYS}" -le 0 ]]; then
  echo "The argument must be a positive integer number of days, for example: 30"
  exit 1
fi

RUNTIME="$(vg_resolve_runtime "${REPO_DIR}")"
exec python3 "${REPO_DIR}/scripts/weekly-health-report.py" --runtime "${RUNTIME}" --days "${DAYS}" "${PY_ARGS[@]}"

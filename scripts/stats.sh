#!/usr/bin/env bash
# VibeGuard statistics script
# Analyze ~/.vibeguard/events.jsonl and output hook trigger statistics
#
# Usage:
# bash stats.sh # Last 7 days
# bash stats.sh 30 # Last 30 days
# bash stats.sh all # All history
# bash stats.sh --scope global 30

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_DIR}/scripts/lib/runtime.sh"

usage() {
  echo "Usage: bash scripts/stats.sh [--scope project|global] [--project PATH_OR_HASH] [--log-file PATH] [DAYS|all]"
}

DAYS="7"
SCOPE="project"
PROJECT_REF=""
LOG_FILE_ARG=""
SCOPE_EXPLICIT=0
PROJECT_EXPLICIT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      SCOPE="$2"
      SCOPE_EXPLICIT=1
      shift 2
      ;;
    --project)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      PROJECT_REF="$2"
      SCOPE="project"
      PROJECT_EXPLICIT=1
      shift 2
      ;;
    --log-file)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      LOG_FILE_ARG="$2"
      shift 2
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

if [[ "${DAYS}" != "all" ]] && { ! [[ "${DAYS}" =~ ^[0-9]+$ ]] || [[ "${DAYS}" -le 0 ]]; }; then
  echo "The argument must be a positive integer number of days or all, for example: 7"
  exit 1
fi

RUNTIME="$(vg_resolve_runtime "${REPO_DIR}")"
CMD=("${RUNTIME}" observe summary --limit all --days "${DAYS}")

if [[ "${SCOPE_EXPLICIT}" -eq 1 ]]; then
  CMD+=(--scope "${SCOPE}")
fi
if [[ "${PROJECT_EXPLICIT}" -eq 1 ]]; then
  CMD+=(--project "${PROJECT_REF}")
fi
if [[ -n "${LOG_FILE_ARG}" ]]; then
  CMD+=(--log-file "${LOG_FILE_ARG}")
fi

exec "${CMD[@]}"

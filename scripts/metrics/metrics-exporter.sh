#!/usr/bin/env bash
# VibeGuard — Prometheus metrics export
#
# Export events.jsonl as Prometheus text format indicators.
# Support pushing to Pushgateway or writing to textfile collector.
#
# Usage:
# bash metrics-exporter.sh # Output to stdout
# bash metrics-exporter.sh --push <gateway> # Push to Pushgateway
# bash metrics-exporter.sh --file <path> # Write textfile
# bash metrics-exporter.sh --project <path-or-hash> # Export one project's metrics

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_DIR}/scripts/lib/runtime.sh"
PUSH_URL=""
OUTPUT_FILE=""
DAYS=7
SINCE=""
SCOPE="global"
INPUT_FILE=""
PROJECT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --push) PUSH_URL="${2:?--push requires a value}"; shift 2 ;;
    --file) OUTPUT_FILE="${2:?--file requires a value}"; shift 2 ;;
    --days) DAYS="${2:?--days requires a value}"; shift 2 ;;
    --since) SINCE="${2:?--since requires a value}"; shift 2 ;;
    --scope) SCOPE="${2:?--scope requires a value}"; shift 2 ;;
    --input-file) INPUT_FILE="${2:?--input-file requires a value}"; shift 2 ;;
    --project) PROJECT="${2:?--project requires a value}"; shift 2 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [[ -z "${SINCE}" ]]; then
  SINCE="${DAYS}d"
fi

RUNTIME="$(vg_resolve_runtime "${REPO_DIR}" observe_export_prometheus)"
CMD=(
  "${RUNTIME}"
  observe
  export
  prometheus
  --scope "${SCOPE}"
  --since "${SINCE}"
)

if [[ -n "${INPUT_FILE}" ]]; then
  CMD+=(--input-file "${INPUT_FILE}")
fi

if [[ -n "${PROJECT}" ]]; then
  CMD+=(--project "${PROJECT}")
fi

if [[ -n "${OUTPUT_FILE}" && -z "${PUSH_URL}" ]]; then
  "${CMD[@]}" --file "${OUTPUT_FILE}"
  echo "Indicator written: ${OUTPUT_FILE}"
elif [[ -n "${PUSH_URL}" ]]; then
  "${CMD[@]}" | curl --silent --data-binary @- "${PUSH_URL}/metrics/job/vibeguard"
  echo "The indicator has been pushed to: ${PUSH_URL}"
else
  "${CMD[@]}"
fi

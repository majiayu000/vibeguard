#!/usr/bin/env bash
# Report U-32 live-constraint budget and low-frequency downgrade candidates.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TARGET_ROOT="${1:-$(pwd)}"
LOG_DIR="${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}"

EVENT_LOGS=()
[[ -f "${LOG_DIR}/events.jsonl" ]] && EVENT_LOGS+=(--events-log "${LOG_DIR}/events.jsonl")
if [[ -d "${LOG_DIR}/projects" ]]; then
  while IFS= read -r -d '' log_file; do
    EVENT_LOGS+=(--events-log "${log_file}")
  done < <(find "${LOG_DIR}/projects" -name events.jsonl -type f -print0 2>/dev/null)
fi

python3 "${REPO_ROOT}/scripts/constraints/count_active_constraints.py" \
  --root "${TARGET_ROOT}" \
  --home "${HOME}" \
  --include-canonical-rules \
  --gc-report \
  "${EVENT_LOGS[@]}"

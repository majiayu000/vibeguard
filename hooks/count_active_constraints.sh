#!/usr/bin/env bash
# VibeGuard SessionStart/UserPromptSubmit Hook — U-32 live constraint budget
#
# Counts the effective constraints that can enter the current agent context.
# >15 emits an advisory, >30 becomes a hard block when strict mode is enabled.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${HOOK_DIR}/log.sh"
source "${HOOK_DIR}/circuit-breaker.sh"
vg_start_timer

# CI guard: the budget is a human-agent context signal, not a CI failure source.
vg_is_ci && exit 0

INPUT=$(cat 2>/dev/null || true)

REPO_DIR="$(cd "${HOOK_DIR}/.." && pwd)"
COUNTER="${REPO_DIR}/scripts/constraints/count_active_constraints.py"
if [[ ! -f "${COUNTER}" ]]; then
  REPO_PATH_FILE="${HOME}/.vibeguard/repo-path"
  if [[ -f "${REPO_PATH_FILE}" ]]; then
    REPO_DIR=$(<"${REPO_PATH_FILE}")
    COUNTER="${REPO_DIR}/scripts/constraints/count_active_constraints.py"
  fi
fi

if [[ ! -f "${COUNTER}" ]]; then
  vg_log "count-active-constraints" "SessionStart" "warn" "counter script missing" "${COUNTER}"
  exit 0
fi

PROJECT_ROOT="${VIBEGUARD_PROJECT_ROOT:-}"
if [[ -z "${PROJECT_ROOT}" ]]; then
  PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
fi

HOOK_EVENT=$(printf '%s' "${INPUT}" | vg_json_field "hook_event_name" 2>/dev/null || true)
HOOK_EVENT="${HOOK_EVENT:-SessionStart}"

COUNTER_ARGS=(--root "${PROJECT_ROOT}" --home "${HOME}" --json)

if [[ -n "${VIBEGUARD_TASK_PATHS:-}" ]]; then
  IFS=',' read -r -a _vg_task_paths <<< "${VIBEGUARD_TASK_PATHS}"
  for _vg_task_path in "${_vg_task_paths[@]}"; do
    [[ -n "${_vg_task_path}" ]] && COUNTER_ARGS+=(--task-path "${_vg_task_path}")
  done
fi

if [[ -n "${VIBEGUARD_ACTIVE_SKILLS:-}" ]]; then
  IFS=',' read -r -a _vg_skills <<< "${VIBEGUARD_ACTIVE_SKILLS}"
  for _vg_skill in "${_vg_skills[@]}"; do
    [[ -n "${_vg_skill}" ]] && COUNTER_ARGS+=(--skill "${_vg_skill}")
  done
fi

REPORT_JSON=$(python3 "${COUNTER}" "${COUNTER_ARGS[@]}" 2>/dev/null || true)
if [[ -z "${REPORT_JSON}" ]]; then
  vg_log "count-active-constraints" "${HOOK_EVENT}" "warn" "constraint counter failed" "${PROJECT_ROOT}"
  exit 0
fi

read -r STATUS TOTAL WARN_THRESHOLD BLOCK_THRESHOLD SUMMARY < <(
  python3 -c '
import json, sys
data = json.load(sys.stdin)
status = data.get("status", "ok")
total = data.get("total", 0)
warn = data.get("warn_threshold", 15)
block = data.get("block_threshold", 30)
sources = sorted(data.get("sources", []), key=lambda item: item.get("count", 0), reverse=True)[:3]
summary = "; ".join(
    "{count} {kind} {path}".format(
        count=item.get("count", 0),
        kind=item.get("kind", "?"),
        path=item.get("path", ""),
    )
    for item in sources
)
print(status, total, warn, block, summary)
' <<< "${REPORT_JSON}"
)

if [[ "${STATUS}" == "ok" ]]; then
  vg_log "count-active-constraints" "${HOOK_EVENT}" "pass" "constraints=${TOTAL}" "${SUMMARY}"
  exit 0
fi

MESSAGE="VIBEGUARD U-32 ${STATUS}: effective task constraints=${TOTAL} (warn>${WARN_THRESHOLD}, block>${BLOCK_THRESHOLD}). Split low-frequency rules into path-scoped files, skills, or hooks before adding more persistent instructions. Top sources: ${SUMMARY}"

if [[ "${STATUS}" == "block" ]]; then
  vg_log "count-active-constraints" "${HOOK_EVENT}" "block" "constraints=${TOTAL}" "${SUMMARY}"
  if [[ "${VIBEGUARD_U32_STRICT:-1}" == "1" ]]; then
    printf '%s\n' "[BLOCKED] ${MESSAGE}" >&2
    exit 2
  fi
else
  vg_log "count-active-constraints" "${HOOK_EVENT}" "warn" "constraints=${TOTAL}" "${SUMMARY}"
fi

VG_HOOK_EVENT="${HOOK_EVENT}" VG_MESSAGE="${MESSAGE}" python3 -c '
import json, os
event = os.environ.get("VG_HOOK_EVENT", "SessionStart")
message = os.environ.get("VG_MESSAGE", "")
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": event,
        "additionalContext": message,
    }
}, ensure_ascii=False))
'

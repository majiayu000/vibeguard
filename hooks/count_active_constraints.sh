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

PROJECT_ROOT="${VIBEGUARD_PROJECT_ROOT:-}"
if [[ -z "${PROJECT_ROOT}" ]]; then
  PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
fi

HOOK_EVENT=$(printf '%s' "${INPUT}" | vg_json_field "hook_event_name" 2>/dev/null || true)
HOOK_EVENT="${HOOK_EVENT:-SessionStart}"

COUNTER_ARGS=(--root "${PROJECT_ROOT}" --home "${HOME}" --hook-fields)

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

REPORT_FIELDS=$("$_VIBEGUARD_RUNTIME" active-constraints "${COUNTER_ARGS[@]}" 2>/dev/null || true)
if [[ -z "${REPORT_FIELDS}" ]]; then
  vg_log "count-active-constraints" "${HOOK_EVENT}" "warn" "constraint counter failed" "${PROJECT_ROOT}"
  exit 0
fi

read -r STATUS TOTAL WARN_THRESHOLD BLOCK_THRESHOLD SUMMARY <<< "${REPORT_FIELDS}"

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

printf '%s' "${MESSAGE}" | "$_VIBEGUARD_RUNTIME" hook-context "${HOOK_EVENT}"

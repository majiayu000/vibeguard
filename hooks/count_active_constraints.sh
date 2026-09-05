#!/usr/bin/env bash
# VibeGuard SessionStart/UserPromptSubmit Hook — U-32 live constraint budget
#
# Estimates candidate constraints from configured files. Counts are diagnostics,
# not evidence of runtime loading or task failure. Every profile is advisory.

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
  # PERF-OK: SessionStart constraint counts are repo-scoped; fallback supports non-git dirs.
  PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
fi

HOOK_EVENT=$(printf '%s' "${INPUT}" | vg_json_field "hook_event_name" 2>/dev/null || true)
HOOK_EVENT="${HOOK_EVENT:-SessionStart}"

COUNTER_ARGS=(--root "${PROJECT_ROOT}" --home "${HOME}" --host claude --hook-fields)

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

MESSAGE="VIBEGUARD U-32 advisory: estimated candidate constraints=${TOTAL} (review thresholds: ${WARN_THRESHOLD}/${BLOCK_THRESHOLD}). This is a file-based estimate, not evidence of what the host actually loaded or a reason to stop this task. Review conflicting or irrelevant guidance when it affects the requested work; preserve owner requirements and continue within the authorized scope. Top sources: ${SUMMARY}"

vg_log "count-active-constraints" "${HOOK_EVENT}" "warn" "U-32 constraints=${TOTAL}" "${SUMMARY}"
printf '%s' "${MESSAGE}" | "$_VIBEGUARD_RUNTIME" hook-context "${HOOK_EVENT}"

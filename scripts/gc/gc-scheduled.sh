#!/usr/bin/env bash
# VibeGuard periodic GC — scheduled by launchd
#
# Execute log archiving + worktree cleaning, metrics pruning, learning digest,
# and reflection reporting. Triggered by com.vibeguard.gc every Sunday at 3am.
#
# Manually run: bash gc-scheduled.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
: "${VIBEGUARD_PROJECT_CONFIG:=${REPO_ROOT}/.vibeguard.json}"
export VIBEGUARD_PROJECT_CONFIG
# shellcheck source=../lib/project_config.sh
source "${SCRIPT_DIR}/../lib/project_config.sh"

LOG_DIR="${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}"
GC_LOG="${LOG_DIR}/gc-cron.log"
GC_STATE_FILE="${LOG_DIR}/gc-last-success"
GC_ATTEMPT_FILE="${LOG_DIR}/gc-last-attempt"
SESSION_METRICS_RETAIN_DAYS="$(vg_config_positive_int VIBEGUARD_GC_SESSION_METRICS_RETAIN_DAYS gc.session_metrics_retain_days 90)"
LEARNING_WINDOW_DAYS="$(vg_config_positive_int VIBEGUARD_GC_LEARNING_WINDOW_DAYS gc.learning_window_days 7)"
GC_LOG_MAX_KB="$(vg_config_positive_int VIBEGUARD_GC_LOG_MAX_KB gc.gc_log_max_kb 1024)"
GC_LOG_THRESHOLD_MB="$(vg_config_positive_int VIBEGUARD_GC_LOG_THRESHOLD_MB gc.log_threshold_mb 10)"
GC_CATCHUP_INTERVAL_HOURS="$(vg_config_positive_int VIBEGUARD_GC_CATCHUP_INTERVAL_HOURS gc.catchup_interval_hours 168)"
SCHEDULED=false
GC_FAILED=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scheduled) SCHEDULED=true; shift ;;
    *) shift ;;
  esac
done

mkdir -p "${LOG_DIR}"

log_file_size_mb() {
  local file="$1"
  [[ -f "$file" ]] || { printf '%s\n' "0"; return 0; }
  du -m "$file" 2>/dev/null | cut -f1
}

find_oversized_logs() {
  local file size
  file="${LOG_DIR}/events.jsonl"
  if [[ -f "$file" ]]; then
    size="$(log_file_size_mb "$file")"
    [[ "$size" =~ ^[0-9]+$ && "$size" -ge "$GC_LOG_THRESHOLD_MB" ]] && printf '%s\t%s\n' "$size" "$file"
  fi
  for file in "${LOG_DIR}"/projects/*/events.jsonl; do
    [[ -f "$file" ]] || continue
    size="$(log_file_size_mb "$file")"
    [[ "$size" =~ ^[0-9]+$ && "$size" -ge "$GC_LOG_THRESHOLD_MB" ]] && printf '%s\t%s\n' "$size" "$file"
  done
}

scheduled_run_due() {
  [[ "$SCHEDULED" == "true" ]] || return 0
  if [[ -n "$(find_oversized_logs)" ]]; then
    return 0
  fi
  [[ -f "$GC_STATE_FILE" ]] || return 0

  local last_success now max_age
  last_success="$(cat "$GC_STATE_FILE" 2>/dev/null || true)"
  [[ "$last_success" =~ ^[0-9]+$ ]] || return 0
  now="$(date +%s)"
  max_age=$((GC_CATCHUP_INTERVAL_HOURS * 3600))
  [[ $((now - last_success)) -ge "$max_age" ]]
}

if ! scheduled_run_due; then
  exit 0
fi

run_gc_log_archive() {
  echo "--- Log archive ---"
  if ! bash "${SCRIPT_DIR}/gc-logs.sh" 2>&1; then
    echo "[ERROR] gc-logs failed"
    GC_FAILED=1
  fi
  local oversized=""
  oversized="$(find_oversized_logs)"
  if [[ -n "$oversized" ]]; then
    while IFS=$'\t' read -r size file; do
      [[ -n "$file" ]] || continue
      echo "[WARN] log remains above threshold after GC: ${file} (${size}MB >= ${GC_LOG_THRESHOLD_MB}MB)"
    done <<< "$oversized"
    GC_FAILED=1
  fi
  echo
}

run_worktree_cleanup() {
  echo "--- Worktree Cleanup ---"
  if ! bash "${SCRIPT_DIR}/gc-worktrees.sh" 2>&1; then
    echo "[ERROR] gc-worktrees failed"
    GC_FAILED=1
  fi
  echo
}

run_rule_budget_gc() {
  echo "--- Rule Budget GC (U-32) ---"
  if ! bash "${SCRIPT_DIR}/gc-rule-budget.sh" "${REPO_ROOT}" 2>&1; then
    echo "[ERROR] gc-rule-budget failed"
    GC_FAILED=1
  fi
  echo
}

run_session_metrics_cleanup() {
  echo "--- Session Metrics Cleanup ---"
  local cutoff
  cutoff=$(date -v-"${SESSION_METRICS_RETAIN_DAYS}"d '+%Y-%m-%dT' 2>/dev/null \
    || date -d "${SESSION_METRICS_RETAIN_DAYS} days ago" '+%Y-%m-%dT' 2>/dev/null \
    || echo "")
  if [[ -n "${cutoff}" ]]; then
    if ! _GC_LOG_DIR="${LOG_DIR}" _GC_CUTOFF="${cutoff}" \
      python3 "${SCRIPT_DIR}/session_metrics_cleanup.py" 2>/dev/null; then
      echo "[ERROR] session-metrics cleanup failed"
      GC_FAILED=1
    fi
  else
    echo "Skip (cannot calculate date)"
  fi
  echo
}

run_learning_digest() {
  echo "--- Regular learning (event log + code scanning unified signal source) ---"
  if ! _GC_LOG_DIR="${LOG_DIR}" \
    _GC_VIBEGUARD_DIR="${REPO_ROOT}" \
    _GC_LEARNING_WINDOW_DAYS="${LEARNING_WINDOW_DAYS}" \
    python3 "${SCRIPT_DIR}/learn_digest.py" 2>&1; then
    echo "[ERROR] learn-digest failed"
    GC_FAILED=1
  fi
  echo
}

run_reflection_digest() {
  echo "---Session Quality Reflection (Reflection Automation) ---"
  local reflection_file="${LOG_DIR}/reflection-digest.md"
  if ! _GC_LOG_DIR="${LOG_DIR}" _GC_REFLECTION_FILE="${reflection_file}" \
    python3 "${SCRIPT_DIR}/reflection_digest.py" 2>&1; then
    echo "[ERROR] reflection failed"
    GC_FAILED=1
  fi
  echo
}

trim_gc_log() {
  [[ -f "${GC_LOG}" ]] || return 0
  local size
  size=$(du -k "${GC_LOG}" | cut -f1)
  if [[ ${size} -gt "${GC_LOG_MAX_KB}" ]]; then
    tail -500 "${GC_LOG}" > "${GC_LOG}.tmp"
    mv "${GC_LOG}.tmp" "${GC_LOG}"
  fi
}

{
  echo "=========================================="
  echo "VibeGuard GC — $(date '+%Y-%m-%d %H:%M:%S')"
  echo "=========================================="
  echo

  run_gc_log_archive
  run_worktree_cleanup
  run_rule_budget_gc
  run_session_metrics_cleanup
  run_learning_digest
  run_reflection_digest

  if [[ "$GC_FAILED" -eq 0 ]]; then
    echo "GC completed"
  else
    echo "GC completed with errors"
  fi
} >> "${GC_LOG}" 2>&1

date +%s > "${GC_ATTEMPT_FILE}"
chmod 600 "${GC_ATTEMPT_FILE}" 2>/dev/null || true
if [[ "$GC_FAILED" -eq 0 ]]; then
  date +%s > "${GC_STATE_FILE}"
  chmod 600 "${GC_STATE_FILE}" 2>/dev/null || true
fi

trim_gc_log

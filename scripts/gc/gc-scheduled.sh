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
SESSION_METRICS_RETAIN_DAYS="$(vg_config_positive_int VIBEGUARD_GC_SESSION_METRICS_RETAIN_DAYS gc.session_metrics_retain_days 90)"
LEARNING_WINDOW_DAYS="$(vg_config_positive_int VIBEGUARD_GC_LEARNING_WINDOW_DAYS gc.learning_window_days 7)"
GC_LOG_MAX_KB="$(vg_config_positive_int VIBEGUARD_GC_LOG_MAX_KB gc.gc_log_max_kb 1024)"

mkdir -p "${LOG_DIR}"

run_gc_log_archive() {
  echo "--- Log archive ---"
  bash "${SCRIPT_DIR}/gc-logs.sh" 2>&1 || echo "[ERROR] gc-logs failed"
  echo
}

run_worktree_cleanup() {
  echo "--- Worktree Cleanup ---"
  bash "${SCRIPT_DIR}/gc-worktrees.sh" 2>&1 || echo "[ERROR] gc-worktrees failed"
  echo
}

run_rule_budget_gc() {
  echo "--- Rule Budget GC (U-32) ---"
  bash "${SCRIPT_DIR}/gc-rule-budget.sh" "${REPO_ROOT}" 2>&1 || echo "[ERROR] gc-rule-budget failed"
  echo
}

run_session_metrics_cleanup() {
  echo "--- Session Metrics Cleanup ---"
  local cutoff
  cutoff=$(date -v-"${SESSION_METRICS_RETAIN_DAYS}"d '+%Y-%m-%dT' 2>/dev/null \
    || date -d "${SESSION_METRICS_RETAIN_DAYS} days ago" '+%Y-%m-%dT' 2>/dev/null \
    || echo "")
  if [[ -n "${cutoff}" ]]; then
    _GC_LOG_DIR="${LOG_DIR}" _GC_CUTOFF="${cutoff}" \
      python3 "${SCRIPT_DIR}/session_metrics_cleanup.py" 2>/dev/null || true
  else
    echo "Skip (cannot calculate date)"
  fi
  echo
}

run_learning_digest() {
  echo "--- Regular learning (event log + code scanning unified signal source) ---"
  _GC_LOG_DIR="${LOG_DIR}" \
    _GC_VIBEGUARD_DIR="${REPO_ROOT}" \
    _GC_LEARNING_WINDOW_DAYS="${LEARNING_WINDOW_DAYS}" \
    python3 "${SCRIPT_DIR}/learn_digest.py" 2>&1 || echo "[ERROR] learn-digest failed"
  echo
}

run_reflection_digest() {
  echo "---Session Quality Reflection (Reflection Automation) ---"
  local reflection_file="${LOG_DIR}/reflection-digest.md"
  _GC_LOG_DIR="${LOG_DIR}" _GC_REFLECTION_FILE="${reflection_file}" \
    python3 "${SCRIPT_DIR}/reflection_digest.py" 2>&1 || echo "[ERROR] reflection failed"
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

  echo "GC completed"
} >> "${GC_LOG}" 2>&1

trim_gc_log

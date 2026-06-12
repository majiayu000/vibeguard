#!/usr/bin/env bash
# VibeGuard Session Metrics + Correction Detection — Stop event metric collection
#
# Benchmark the data collection layer of the Harness feedback loop:
# Collect session metrics → detect correction signals → write project-level metrics → for consumption by stats/gc/learn
#
# Correct signal detection (see Codex "mistake twice → retrospective"):
# - high warn rate (>40%) → low session quality
# - File churn (same file edited 5+ times) → repeated corrections
# - correction event exists → real-time correction detection triggered
# Output suggestions when significant signals are detected (not blocking)
set -euo pipefail
source "$(dirname "$0")/log.sh"
vg_start_timer

vg_learn_is_ci() {
  case "${CI:-}" in true|True|TRUE|1|yes|Yes|YES) return 0 ;; esac
  case "${GITHUB_ACTIONS:-}" in true|True|TRUE|1|yes|Yes|YES) return 0 ;; esac
  case "${TRAVIS:-}" in true|True|TRUE|1|yes|Yes|YES) return 0 ;; esac
  case "${CIRCLECI:-}" in true|True|TRUE|1|yes|Yes|YES) return 0 ;; esac
  [[ -n "${JENKINS_URL:-}" ]] && return 0
  case "${GITLAB_CI:-}" in true|True|TRUE|1|yes|Yes|YES) return 0 ;; esac
  case "${TF_BUILD:-}" in true|True|TRUE|1|yes|Yes|YES) return 0 ;; esac
  return 1
}

vg_learn_stop_hook_active_fast() {
  local input="$1" active=""
  active=$(printf '%s' "$input" | "$_VIBEGUARD_RUNTIME" json-field stop_hook_active 2>/dev/null || true)
  [[ "$active" == "true" ]]
}

vg_learn_recent_events() {
  local log_file="$1" tail_bytes="$2"
  [[ -f "$log_file" ]] || return 0
  if [[ "$tail_bytes" =~ ^[0-9]+$ && "$tail_bytes" -gt 0 ]]; then
    tail -c "$tail_bytes" "$log_file" 2>/dev/null || cat "$log_file" 2>/dev/null || true
  else
    cat "$log_file" 2>/dev/null || true
  fi
}

vg_learn_log_truncation_once() {
  local log_file="$1" tail_bytes="$2"
  [[ -f "$log_file" ]] || return 0
  [[ "$tail_bytes" =~ ^[0-9]+$ && "$tail_bytes" -gt 0 ]] || return 0

  local size_bytes session_key flag_file
  size_bytes="$(wc -c < "$log_file" 2>/dev/null | tr -d ' ' || echo 0)"
  [[ "$size_bytes" =~ ^[0-9]+$ && "$size_bytes" -gt "$tail_bytes" ]] || return 0
  session_key="$(printf '%s' "${VIBEGUARD_SESSION_ID:-unknown}" | tr -c 'A-Za-z0-9_.-' '_')"
  flag_file="${VIBEGUARD_LOG_DIR}/.learn_metrics_truncated_${session_key}"
  [[ -f "$flag_file" ]] && return 0
  : > "$flag_file" 2>/dev/null || true
  vg_log "learn-evaluator" "Stop" "warn" \
    "metrics input truncated to ${tail_bytes} bytes before 30-minute filter; increase VIBEGUARD_LEARN_METRICS_TAIL_BYTES for very busy sessions" \
    "$log_file"
}

# CI guard: skip in automated environments
vg_learn_is_ci && exit 0

# Read stdin; check stop_hook_active to break Stop-hook chain loops
INPUT=$(cat 2>/dev/null || true)
vg_learn_stop_hook_active_fast "$INPUT" && exit 0

# Not in git repository → skip
if ! git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
  exit 0
fi

# Collect session metrics for the last 30 minutes of the current project. Bound
# the input before the runtime filter so old logs cannot make every Stop hook
# linearly slower as events.jsonl grows.
vg_config_get_int_result LEARN_TAIL_BYTES VIBEGUARD_LEARN_METRICS_TAIL_BYTES learn.metrics_tail_bytes 5242880
vg_learn_log_truncation_once "$VIBEGUARD_LOG_FILE" "$LEARN_TAIL_BYTES"
LEARN_SUGGESTION=$(vg_learn_recent_events "$VIBEGUARD_LOG_FILE" "$LEARN_TAIL_BYTES" \
  | "$_VIBEGUARD_RUNTIME" session-metrics "$VIBEGUARD_SESSION_ID" "$VIBEGUARD_PROJECT_LOG_DIR" 2>/dev/null || true)

# If a correction signal is detected, output suggestions (not blocking)
if [[ "$LEARN_SUGGESTION" == LEARN_SUGGESTED* ]]; then
  SIGNALS=$(echo "$LEARN_SUGGESTION" | tail -n +2)
  SIGNAL_COUNT=$(echo "$SIGNALS" | wc -l | tr -d ' ')

  # Stop hook only supports top-level fields, hookSpecificOutput is not supported.
  SIGNAL_LIST=$(printf '%s\n' "$SIGNALS" \
    | sed '/^[[:space:]]*$/d' \
    | awk 'BEGIN { first = 1 } { if (!first) printf "; "; printf "%s", $0; first = 0 }')
  printf '[VibeGuard correction detection] %s signals: %s. It is recommended to run /vibeguard:learn' \
    "$SIGNAL_COUNT" "$SIGNAL_LIST" \
    | "$_VIBEGUARD_RUNTIME" stop-reason
fi

# Clean up the churn flag file of this session. Keep the scan bounded and
# respect benchmark/test log isolation.
_VG_CHURN_DIR="${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}"
find "$_VG_CHURN_DIR" -maxdepth 1 -name ".churn_warned_${VIBEGUARD_SESSION_ID}_*" -delete 2>/dev/null || true

exit 0

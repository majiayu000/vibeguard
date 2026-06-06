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

# CI guard: skip in automated environments
vg_learn_is_ci && exit 0

# Read stdin; check stop_hook_active to break Stop-hook chain loops
INPUT=$(cat 2>/dev/null || true)
vg_learn_stop_hook_active_fast "$INPUT" && exit 0

# Not in git repository → skip
if ! git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
  exit 0
fi

# Collect session metrics for the last 30 minutes of the current project + correct signal detection
# Pass the full log file — the 30-minute cutoff is enforced inside vibeguard-runtime,
# so tail-limiting here would under-count events on busy sessions (>1000 events/30 min).
LEARN_SUGGESTION=$("$_VIBEGUARD_RUNTIME" session-metrics "$VIBEGUARD_SESSION_ID" "$VIBEGUARD_PROJECT_LOG_DIR" \
  < "$VIBEGUARD_LOG_FILE" 2>/dev/null || true)

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

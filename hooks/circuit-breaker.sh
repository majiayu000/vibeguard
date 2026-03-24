#!/usr/bin/env bash
# VibeGuard Hook Circuit Breaker
#
# Prevents infinite loops when a hook repeatedly blocks/warns in an unresolvable condition.
# Implements Martin Fowler's circuit breaker: CLOSED → OPEN (cooldown) → HALF-OPEN → CLOSED
#
# States:
#   CLOSED    — normal operation; blocks/warns are recorded
#   OPEN      — tripped after CB_THRESHOLD consecutive blocks; auto-pass for CB_COOLDOWN seconds
#   HALF-OPEN — one probe attempt after cooldown; pass → CLOSED, block → back to OPEN
#
# Usage (source after log.sh):
#   source "$(dirname "$0")/circuit-breaker.sh"
#
#   # In a hook that can block:
#   vg_cb_check "my-hook" || { vg_log "my-hook" "Tool" "pass" "CB auto-pass" ""; exit 0; }
#   if [[ blocking_condition ]]; then
#     vg_cb_record_block "my-hook"
#     exit 2
#   fi
#   vg_cb_record_pass "my-hook"

# ── Configuration ────────────────────────────────────────────────────────────
CB_DIR="${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}/circuit-breaker"
CB_COOLDOWN="${VG_CB_COOLDOWN:-300}"   # seconds until OPEN → HALF-OPEN (5 min)
CB_THRESHOLD="${VG_CB_THRESHOLD:-3}"   # consecutive blocks before tripping to OPEN

mkdir -p "$CB_DIR" 2>/dev/null || true

# ── Internal helpers ─────────────────────────────────────────────────────────

_vg_cb_now() { date +%s; }

# Emit a log entry if vg_log is available (log.sh may not be sourced in tests)
_vg_cb_log() {
  if declare -f vg_log &>/dev/null; then
    vg_log "$@"
  fi
}

# Load state for <hook> into CB_STATE / CB_BLOCKS / CB_LAST_BLOCK / CB_SESSION
_vg_cb_load() {
  local hook="$1"
  local state_file="${CB_DIR}/${hook}.cb"
  CB_STATE="CLOSED"
  CB_BLOCKS=0
  CB_LAST_BLOCK=0
  CB_SESSION=""
  if [[ -f "$state_file" ]]; then
    # shellcheck source=/dev/null
    source "$state_file" 2>/dev/null || true
  fi
  # Reset if the state belongs to a different session
  local cur_session="${VIBEGUARD_SESSION_ID:-}"
  if [[ -n "$cur_session" && -n "$CB_SESSION" && "$CB_SESSION" != "$cur_session" ]]; then
    CB_STATE="CLOSED"
    CB_BLOCKS=0
    CB_LAST_BLOCK=0
    CB_SESSION=""
  fi
}

# Persist CB_STATE / CB_BLOCKS / CB_LAST_BLOCK / CB_SESSION for <hook>
_vg_cb_save() {
  local hook="$1"
  local state_file="${CB_DIR}/${hook}.cb"
  {
    printf 'CB_STATE=%s\n' "$CB_STATE"
    printf 'CB_BLOCKS=%s\n' "$CB_BLOCKS"
    printf 'CB_LAST_BLOCK=%s\n' "$CB_LAST_BLOCK"
    printf 'CB_SESSION=%s\n' "${VIBEGUARD_SESSION_ID:-}"
  } > "$state_file" 2>/dev/null || true
}

# ── Public API ───────────────────────────────────────────────────────────────

# vg_cb_check <hook>
# Returns 0 if the hook should run normally.
# Returns 1 if the circuit is OPEN and the call should be auto-passed.
# Transitions OPEN → HALF-OPEN when the cooldown has expired.
vg_cb_check() {
  local hook="$1"
  _vg_cb_load "$hook"
  local now
  now=$(_vg_cb_now)

  case "$CB_STATE" in
    CLOSED)
      return 0
      ;;
    OPEN)
      local elapsed=$(( now - CB_LAST_BLOCK ))
      if [[ "$elapsed" -ge "$CB_COOLDOWN" ]]; then
        CB_STATE="HALF-OPEN"
        _vg_cb_save "$hook"
        return 0  # Let one probe through
      else
        local remaining=$(( CB_COOLDOWN - elapsed ))
        _vg_cb_log "$hook" "circuit-breaker" "pass" \
          "CB OPEN: auto-pass (${remaining}s remaining, ${CB_BLOCKS} consecutive blocks)" ""
        return 1  # Auto-pass: caller should skip hook logic and exit 0
      fi
      ;;
    HALF-OPEN)
      return 0  # Probe attempt: let it through
      ;;
    *)
      CB_STATE="CLOSED"; CB_BLOCKS=0
      _vg_cb_save "$hook"
      return 0
      ;;
  esac
}

# vg_cb_record_block <hook>
# Records one block/warn event. Trips circuit to OPEN after CB_THRESHOLD consecutive events.
vg_cb_record_block() {
  local hook="$1"
  _vg_cb_load "$hook"
  CB_BLOCKS=$(( CB_BLOCKS + 1 ))
  CB_LAST_BLOCK=$(_vg_cb_now)

  if [[ "$CB_STATE" == "HALF-OPEN" ]] || [[ "$CB_BLOCKS" -ge "$CB_THRESHOLD" ]]; then
    CB_STATE="OPEN"
    _vg_cb_log "$hook" "circuit-breaker" "warn" \
      "CB tripped OPEN: ${CB_BLOCKS} consecutive blocks, cooldown ${CB_COOLDOWN}s" ""
  fi
  _vg_cb_save "$hook"
}

# vg_cb_record_pass <hook>
# Records a successful (non-blocking) result. Resets circuit to CLOSED.
vg_cb_record_pass() {
  local hook="$1"
  _vg_cb_load "$hook"
  if [[ "$CB_STATE" != "CLOSED" ]] || [[ "$CB_BLOCKS" -gt 0 ]]; then
    CB_STATE="CLOSED"
    CB_BLOCKS=0
    CB_LAST_BLOCK=0
    _vg_cb_save "$hook"
  fi
}

# ── CI guard ─────────────────────────────────────────────────────────────────

# vg_is_ci
# Returns 0 (true) if running inside a CI environment.
# Hooks that rely on desktop-only context should call:  vg_is_ci && exit 0
vg_is_ci() {
  [[ -n "${CI:-}" ]] \
    || [[ -n "${GITHUB_ACTIONS:-}" ]] \
    || [[ -n "${TRAVIS:-}" ]] \
    || [[ -n "${CIRCLECI:-}" ]] \
    || [[ -n "${JENKINS_URL:-}" ]] \
    || [[ -n "${GITLAB_CI:-}" ]] \
    || [[ -n "${TF_BUILD:-}" ]]
}

# ── stop_hook_active guard ────────────────────────────────────────────────────

# vg_stop_hook_active <json_string>
# Returns 0 (true) if the Stop hook input JSON has stop_hook_active == true,
# indicating this invocation was triggered by another Stop hook and should not block.
# Usage:  vg_stop_hook_active "$INPUT" && exit 0
vg_stop_hook_active() {
  local input="$1"
  VG_CB_INPUT="$input" python3 -c "
import json, os, sys
try:
    data = json.loads(os.environ.get('VG_CB_INPUT', '{}'))
    sys.exit(0 if data.get('stop_hook_active', False) else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null
}

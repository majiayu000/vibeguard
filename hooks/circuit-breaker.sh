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

# Validate that a value is a non-negative integer; fall back to default if not.
# Prevents arithmetic errors under set -euo pipefail when env vars are misconfigured.
_vg_cb_to_int() { local v="$1" d="$2"; [[ "$v" =~ ^[0-9]+$ ]] && printf '%s' "$v" || printf '%s' "$d"; }

CB_COOLDOWN=$(_vg_cb_to_int "${VG_CB_COOLDOWN:-300}" 300)   # seconds until OPEN → HALF-OPEN (5 min)
CB_THRESHOLD=$(_vg_cb_to_int "${VG_CB_THRESHOLD:-3}" 3)     # consecutive blocks before tripping to OPEN

mkdir -p "$CB_DIR" 2>/dev/null || true

# ── Internal helpers ─────────────────────────────────────────────────────────

_vg_cb_now() { date +%s; }

# Emit a log entry if vg_log is available (log.sh may not be sourced in tests)
_vg_cb_log() {
  if declare -f vg_log &>/dev/null; then
    vg_log "$@"
  fi
}

# Return the per-project state file path for <hook>.
# Reuses _vg_project_hash from log.sh if already computed in this shell;
# otherwise computes it fresh from git so state is isolated per repository.
_vg_cb_state_file() {
  local hook="$1"
  local slug
  if [[ -n "${_vg_project_hash:-}" ]]; then
    slug="$_vg_project_hash"
  else
    local root
    root=$(git rev-parse --show-toplevel 2>/dev/null || echo "global")
    slug=$(printf '%s' "$root" | shasum -a 256 2>/dev/null | cut -c1-8) || slug="fallback0"
  fi
  printf '%s/%s/%s.cb' "$CB_DIR" "$slug" "$hook"
}

# Return the exclusive lock file path for <hook> (sibling of the state file).
_vg_cb_lock_file() {
  local hook="$1"
  printf '%s.lock' "$(_vg_cb_state_file "$hook")"
}

# Acquire an exclusive flock on fd <n>, waiting up to 5 seconds.
# Silently skips if flock(1) is unavailable (e.g., macOS without util-linux).
# Always returns 0 so callers under set -euo pipefail are not aborted.
_vg_cb_try_flock() {
  command -v flock >/dev/null 2>&1 && flock -x -w 5 "$1" 2>/dev/null || true
}

# Load state for <hook> into CB_STATE / CB_BLOCKS / CB_LAST_BLOCK / CB_SESSION
_vg_cb_load() {
  local hook="$1"
  local state_file
  state_file=$(_vg_cb_state_file "$hook")
  CB_STATE="CLOSED"
  CB_BLOCKS=0
  CB_LAST_BLOCK=0
  CB_SESSION=""
  if [[ -f "$state_file" ]]; then
    # Safe key=value parser — never executes the file as shell code.
    # Each field is validated before assignment to prevent injection via a
    # tampered state file (e.g. malicious VIBEGUARD_SESSION_ID).
    local _line _key _val
    while IFS= read -r _line; do
      _key="${_line%%=*}"
      _val="${_line#*=}"
      case "$_key" in
        CB_STATE)
          case "$_val" in
            CLOSED|OPEN|HALF-OPEN) CB_STATE="$_val" ;;
          esac
          ;;
        CB_BLOCKS)
          [[ "$_val" =~ ^[0-9]+$ ]] && CB_BLOCKS="$_val"
          ;;
        CB_LAST_BLOCK)
          [[ "$_val" =~ ^[0-9]+$ ]] && CB_LAST_BLOCK="$_val"
          ;;
        CB_SESSION)
          # Allow only characters safe for a session ID (UUID / slug)
          [[ "$_val" =~ ^[a-zA-Z0-9_=-]*$ ]] && CB_SESSION="$_val"
          ;;
      esac
    done < "$state_file"
  fi
  # Reset if the state belongs to a different session
  local cur_session="${VIBEGUARD_SESSION_ID:-}"
  if [[ -n "$cur_session" && -n "$CB_SESSION" && "$CB_SESSION" != "$cur_session" ]]; then
    CB_STATE="CLOSED"
    CB_BLOCKS=0
    CB_LAST_BLOCK=0
    CB_SESSION=""
    _vg_cb_save "$hook"
  fi
}

# Persist CB_STATE / CB_BLOCKS / CB_LAST_BLOCK / CB_SESSION for <hook>.
# Writes to a temp file then renames for atomicity, preventing concurrent
# readers from seeing a partial/empty state file.
_vg_cb_save() {
  local hook="$1"
  local state_file tmp_file
  state_file=$(_vg_cb_state_file "$hook")
  mkdir -p "$(dirname "$state_file")" 2>/dev/null || true
  tmp_file="${state_file}.tmp.$$"
  {
    printf 'CB_STATE=%s\n' "$CB_STATE"
    printf 'CB_BLOCKS=%s\n' "$CB_BLOCKS"
    printf 'CB_LAST_BLOCK=%s\n' "$CB_LAST_BLOCK"
    printf 'CB_SESSION=%s\n' "${VIBEGUARD_SESSION_ID:-}"
  } > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$state_file" 2>/dev/null || true
}

# ── Public API ───────────────────────────────────────────────────────────────

# vg_cb_check <hook>
# Returns 0 if the hook should run normally.
# Returns 1 if the circuit is OPEN and the call should be auto-passed.
# Transitions OPEN → HALF-OPEN when the cooldown has expired.
# The entire read-decide-write cycle runs inside an exclusive flock to prevent
# concurrent hook invocations from racing on the state file.
vg_cb_check() {
  local hook="$1"
  local lock_file
  lock_file=$(_vg_cb_lock_file "$hook")
  mkdir -p "$(dirname "$lock_file")" 2>/dev/null || true
  (
    _vg_cb_try_flock 9
    _vg_cb_load "$hook"
    now=$(_vg_cb_now)

    case "$CB_STATE" in
      CLOSED)
        exit 0
        ;;
      OPEN)
        elapsed=$(( now - CB_LAST_BLOCK ))
        if [[ "$elapsed" -ge "$CB_COOLDOWN" ]]; then
          CB_STATE="HALF-OPEN"
          CB_LAST_BLOCK=$(_vg_cb_now)
          _vg_cb_save "$hook"
          exit 0  # Let one probe through
        else
          remaining=$(( CB_COOLDOWN - elapsed ))
          _vg_cb_log "$hook" "circuit-breaker" "pass" \
            "CB OPEN: auto-pass (${remaining}s remaining, ${CB_BLOCKS} consecutive blocks)" ""
          exit 1  # Auto-pass: caller should skip hook logic and exit 0
        fi
        ;;
      HALF-OPEN)
        # Probe already in flight (dispatched when OPEN→HALF-OPEN transition
        # ran exit 0 above).  Auto-pass subsequent callers until
        # vg_cb_record_pass/block transitions state back to CLOSED or OPEN.
        _vg_cb_log "$hook" "circuit-breaker" "pass" \
          "CB HALF-OPEN: probe in-flight, auto-passing (${CB_BLOCKS} prior blocks)" ""
        exit 1
        ;;
      *)
        CB_STATE="CLOSED"; CB_BLOCKS=0
        _vg_cb_save "$hook"
        exit 0
        ;;
    esac
  ) 9>"$lock_file"
}

# vg_cb_record_block <hook>
# Records one block/warn event. Trips circuit to OPEN after CB_THRESHOLD consecutive events.
# Protected by an exclusive flock to prevent lost-update races under concurrent access.
vg_cb_record_block() {
  local hook="$1"
  local lock_file
  lock_file=$(_vg_cb_lock_file "$hook")
  mkdir -p "$(dirname "$lock_file")" 2>/dev/null || true
  (
    _vg_cb_try_flock 9
    _vg_cb_load "$hook"
    CB_BLOCKS=$(( CB_BLOCKS + 1 ))
    CB_LAST_BLOCK=$(_vg_cb_now)

    if [[ "$CB_STATE" == "HALF-OPEN" ]] || [[ "$CB_BLOCKS" -ge "$CB_THRESHOLD" ]]; then
      CB_STATE="OPEN"
      _vg_cb_log "$hook" "circuit-breaker" "warn" \
        "CB tripped OPEN: ${CB_BLOCKS} consecutive blocks, cooldown ${CB_COOLDOWN}s" ""
    fi
    _vg_cb_save "$hook"
  ) 9>"$lock_file"
}

# vg_cb_record_pass <hook>
# Records a successful (non-blocking) result. Resets circuit to CLOSED.
# Protected by an exclusive flock to prevent lost-update races under concurrent access.
vg_cb_record_pass() {
  local hook="$1"
  local lock_file
  lock_file=$(_vg_cb_lock_file "$hook")
  mkdir -p "$(dirname "$lock_file")" 2>/dev/null || true
  (
    _vg_cb_try_flock 9
    _vg_cb_load "$hook"
    if [[ "$CB_STATE" != "CLOSED" ]] || [[ "$CB_BLOCKS" -gt 0 ]]; then
      CB_STATE="CLOSED"
      CB_BLOCKS=0
      CB_LAST_BLOCK=0
      _vg_cb_save "$hook"
    fi
  ) 9>"$lock_file"
}

# ── CI guard ─────────────────────────────────────────────────────────────────

# _vg_is_truthy <value>
# Returns 0 if the value is a recognized truthy CI flag: true, True, TRUE, 1, yes, Yes, YES.
# This prevents CI=false or CI=0 from being misread as "running in CI".
_vg_is_truthy() {
  case "${1:-}" in
    true|True|TRUE|1|yes|Yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# vg_is_ci
# Returns 0 (true) if running inside a CI environment.
# Only truthy values (true/1/yes) are accepted; CI=false or CI=0 are treated as "not CI".
# Hooks that rely on desktop-only context should call:  vg_is_ci && exit 0
vg_is_ci() {
  _vg_is_truthy "${CI:-}" \
    || _vg_is_truthy "${GITHUB_ACTIONS:-}" \
    || _vg_is_truthy "${TRAVIS:-}" \
    || _vg_is_truthy "${CIRCLECI:-}" \
    || [[ -n "${JENKINS_URL:-}" ]] \
    || _vg_is_truthy "${GITLAB_CI:-}" \
    || _vg_is_truthy "${TF_BUILD:-}"
}

# ── stop_hook_active guard ────────────────────────────────────────────────────

# vg_stop_hook_active <json_string>
# Returns 0 (true) if the Stop hook input JSON has stop_hook_active == true,
# indicating this invocation was triggered by another Stop hook and should not block.
# Usage:  vg_stop_hook_active "$INPUT" && exit 0
#
# Passes JSON via stdin (pipe) instead of an environment variable to avoid
# hitting execve env-size limits when the input contains a long last_assistant_message.
vg_stop_hook_active() {
  local input="$1"
  printf '%s' "$input" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    val = data.get('stop_hook_active', False)
    # Require the boolean literal true, not a truthy string like 'false'
    sys.exit(0 if val is True else 1)
except Exception:
    sys.exit(1)
"
}

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
#   if vg_cb_check "my-hook"; then
#     cb_status=0
#   else
#     cb_status=$?
#   fi
#   # cb_status: 0 = run normally, 1 = circuit auto-pass, 2+ = lock/state error
#   if [[ blocking_condition ]]; then
#     vg_cb_record_block "my-hook"
#     exit 2
#   fi
#   vg_cb_record_pass "my-hook"

# ── Configuration ────────────────────────────────────────────────────────────
CB_DIR="${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}/circuit-breaker"
_VG_CB_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F vg_config_get_int >/dev/null 2>&1 && [[ -f "${_VG_CB_SCRIPT_DIR}/_lib/config.sh" ]]; then
  source "${_VG_CB_SCRIPT_DIR}/_lib/config.sh"
fi

# Validate that a value is a non-negative integer; fall back to default if not.
# Prevents arithmetic errors under set -euo pipefail when env vars are misconfigured.
_vg_cb_to_int() { local v="$1" d="$2"; [[ "$v" =~ ^[0-9]+$ ]] && printf '%s' "$v" || printf '%s' "$d"; }

if declare -F vg_config_get_int_result >/dev/null 2>&1; then
  vg_config_get_int_result _vg_cb_cooldown VG_CB_COOLDOWN circuit_breaker.cooldown_seconds 300
  vg_config_get_int_result _vg_cb_threshold VG_CB_THRESHOLD circuit_breaker.threshold 3
  vg_config_get_int_result _vg_cb_lock_timeout VG_CB_LOCK_TIMEOUT_SECONDS circuit_breaker.lock_timeout_seconds 5
  CB_COOLDOWN=$(_vg_cb_to_int "$_vg_cb_cooldown" 300)
  CB_THRESHOLD=$(_vg_cb_to_int "$_vg_cb_threshold" 3)
  CB_LOCK_TIMEOUT_SECONDS=$(_vg_cb_to_int "$_vg_cb_lock_timeout" 5)
elif declare -F vg_config_get_int >/dev/null 2>&1; then
  CB_COOLDOWN=$(_vg_cb_to_int "$(vg_config_get_int VG_CB_COOLDOWN circuit_breaker.cooldown_seconds 300)" 300)
  CB_THRESHOLD=$(_vg_cb_to_int "$(vg_config_get_int VG_CB_THRESHOLD circuit_breaker.threshold 3)" 3)
  CB_LOCK_TIMEOUT_SECONDS=$(_vg_cb_to_int "$(vg_config_get_int VG_CB_LOCK_TIMEOUT_SECONDS circuit_breaker.lock_timeout_seconds 5)" 5)
else
  CB_COOLDOWN=$(_vg_cb_to_int "${VG_CB_COOLDOWN:-300}" 300)
  CB_THRESHOLD=$(_vg_cb_to_int "${VG_CB_THRESHOLD:-3}" 3)
  CB_LOCK_TIMEOUT_SECONDS=$(_vg_cb_to_int "${VG_CB_LOCK_TIMEOUT_SECONDS:-5}" 5)
fi

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
  elif [[ -n "${VIBEGUARD_PROJECT_HASH:-}" ]]; then
    slug="$VIBEGUARD_PROJECT_HASH"
  else
    local root
    # PERF-OK: circuit state is repo-scoped; this falls back to global outside git.
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

# Acquire an exclusive lock on fd $1, waiting up to CB_LOCK_TIMEOUT_SECONDS.
# Uses flock(1) when available (Linux). On macOS (no flock), falls back to
# a mkdir-based spinlock on the lock file path associated with fd $1.
_VG_CB_LOCK_OWNED=false
_VG_CB_LOCK_DIR=""

_vg_cb_try_flock() {
  local lock_fd="$1"
  local lock_file_path="${2:-}"
  _VG_CB_LOCK_OWNED=false
  _VG_CB_LOCK_DIR=""

  if command -v flock >/dev/null 2>&1; then
    if flock -x -w "$CB_LOCK_TIMEOUT_SECONDS" "$lock_fd" 2>/dev/null; then
      return 0
    fi
    printf 'VIBEGUARD ERROR: circuit breaker lock timeout for %s after %ss\n' "${lock_file_path:-fd:$lock_fd}" "$CB_LOCK_TIMEOUT_SECONDS" >&2
    return 2
  else
    # macOS fallback: mkdir is atomic on all POSIX systems.
    # Store the acquired lock dir in module state so EXIT traps do not depend
    # on a caller-local lock_file variable still being in scope.
    if [[ -z "$lock_file_path" ]]; then
      printf 'VIBEGUARD ERROR: circuit breaker lock path missing for fd %s\n' "$lock_fd" >&2
      return 2
    fi
    local lockdir="${lock_file_path}.d"
    local max_attempts=$(( CB_LOCK_TIMEOUT_SECONDS * 10 ))
    [[ "$max_attempts" -gt 0 ]] || max_attempts=1
    local _i=0
    while [[ $_i -lt "$max_attempts" ]]; do
      if mkdir "$lockdir" 2>/dev/null; then
        _VG_CB_LOCK_OWNED=true
        _VG_CB_LOCK_DIR="$lockdir"
        return 0
      fi
      sleep 0.1
      _i=$((_i + 1))
    done
    printf 'VIBEGUARD ERROR: circuit breaker lock timeout for %s after %ss\n' "$lock_file_path" "$CB_LOCK_TIMEOUT_SECONDS" >&2
    return 2
  fi
}

# Release the mkdir-based lock only if this process owns it.
_vg_cb_release_flock() {
  if [[ "$_VG_CB_LOCK_OWNED" == "true" && -n "$_VG_CB_LOCK_DIR" ]]; then
    rmdir "$_VG_CB_LOCK_DIR" 2>/dev/null || true
    _VG_CB_LOCK_OWNED=false
    _VG_CB_LOCK_DIR=""
  fi
}

_vg_cb_runtime_available() {
  [[ -n "${_VIBEGUARD_RUNTIME:-}" && -x "$_VIBEGUARD_RUNTIME" ]]
}

_vg_cb_runtime_call() {
  local action="$1"
  local hook="$2"
  local state_file lock_file output err_file err_output status token reason
  state_file=$(_vg_cb_state_file "$hook")
  lock_file=$(_vg_cb_lock_file "$hook")

  if ! err_file=$(mktemp "${TMPDIR:-/tmp}/vibeguard-cb-runtime.XXXXXX"); then
    printf 'VIBEGUARD ERROR: failed to create circuit breaker runtime stderr capture\n' >&2
    return 2
  fi

  if output=$("$_VIBEGUARD_RUNTIME" circuit-breaker "$action" "$hook" "$state_file" "$lock_file" "$CB_THRESHOLD" "$CB_COOLDOWN" "$CB_LOCK_TIMEOUT_SECONDS" 2>"$err_file"); then
    status=0
  else
    status=$?
  fi
  if ! err_output=$(cat "$err_file"); then
    printf 'VIBEGUARD ERROR: failed to read circuit breaker runtime stderr: %s\n' "$err_file" >&2
    rm -f "$err_file" || printf 'VIBEGUARD ERROR: failed to remove circuit breaker runtime stderr capture: %s\n' "$err_file" >&2
    return 2
  fi
  if ! rm -f "$err_file"; then
    printf 'VIBEGUARD ERROR: failed to remove circuit breaker runtime stderr capture: %s\n' "$err_file" >&2
    return 2
  fi

  if [[ "$status" -ne 0 ]]; then
    if [[ "$err_output" == *"Unknown command: circuit-breaker"* || "$output" == *"Unknown command: circuit-breaker"* ]]; then
      return 127
    fi
    [[ -z "$err_output" ]] || printf '%s\n' "$err_output" >&2
    [[ -z "$output" ]] || printf '%s\n' "$output" >&2
    return 2
  fi

  if [[ -n "$err_output" ]]; then
    printf '%s\n' "$err_output" >&2
    return 2
  fi

  token="${output%%$'\n'*}"
  reason="${output#*$'\n'}"
  [[ "$reason" == "$output" ]] && reason=""

  case "$action:$token" in
    check:RUN)
      return 0
      ;;
    check:AUTO_PASS)
      [[ -z "$reason" ]] || _vg_cb_log "$hook" "circuit-breaker" "pass" "$reason" ""
      return 1
      ;;
    record-block:RECORDED|record-pass:RECORDED)
      return 0
      ;;
    record-block:OPENED)
      [[ -z "$reason" ]] || _vg_cb_log "$hook" "circuit-breaker" "warn" "$reason" ""
      return 0
      ;;
    *)
      printf 'VIBEGUARD ERROR: unexpected circuit breaker runtime output for %s/%s: %s\n' "$action" "$hook" "$output" >&2
      return 2
      ;;
  esac
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
    done < "$state_file" || {
      printf 'VIBEGUARD ERROR: failed to read circuit breaker state: %s\n' "$state_file" >&2
      return 2
    }
  fi
  # Reset if the state belongs to a different session
  local cur_session="${VIBEGUARD_SESSION_ID:-}"
  if [[ -n "$cur_session" && -n "$CB_SESSION" && "$CB_SESSION" != "$cur_session" ]]; then
    CB_STATE="CLOSED"
    CB_BLOCKS=0
    CB_LAST_BLOCK=0
    CB_SESSION=""
    _vg_cb_save "$hook" || return 2
  fi
  return 0
}

# Persist CB_STATE / CB_BLOCKS / CB_LAST_BLOCK / CB_SESSION for <hook>.
# Writes to a temp file then renames for atomicity, preventing concurrent
# readers from seeing a partial/empty state file.
_vg_cb_save() {
  local hook="$1"
  local state_file tmp_file
  state_file=$(_vg_cb_state_file "$hook")
  if ! mkdir -p "$(dirname "$state_file")" 2>/dev/null; then
    printf 'VIBEGUARD ERROR: failed to create circuit breaker state directory: %s\n' "$(dirname "$state_file")" >&2
    return 2
  fi
  tmp_file="${state_file}.tmp.$$"
  if ! ( : > "$tmp_file" ) 2>/dev/null; then
    printf 'VIBEGUARD ERROR: failed to write circuit breaker state temp file: %s\n' "$tmp_file" >&2
    rm -f "$tmp_file" 2>/dev/null || true
    return 2
  fi
  if ! {
    printf 'CB_STATE=%s\n' "$CB_STATE"
    printf 'CB_BLOCKS=%s\n' "$CB_BLOCKS"
    printf 'CB_LAST_BLOCK=%s\n' "$CB_LAST_BLOCK"
    printf 'CB_SESSION=%s\n' "${VIBEGUARD_SESSION_ID:-}"
  } > "$tmp_file" 2>/dev/null; then
    printf 'VIBEGUARD ERROR: failed to write circuit breaker state temp file: %s\n' "$tmp_file" >&2
    rm -f "$tmp_file" 2>/dev/null || true
    return 2
  fi
  if ! mv "$tmp_file" "$state_file" 2>/dev/null; then
    printf 'VIBEGUARD ERROR: failed to persist circuit breaker state: %s\n' "$state_file" >&2
    rm -f "$tmp_file" 2>/dev/null || true
    return 2
  fi
  return 0
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
  local status
  if _vg_cb_runtime_available; then
    if _vg_cb_runtime_call "check" "$hook"; then
      return 0
    else
      status=$?
      if [[ "$status" -ne 127 ]]; then
        return "$status"
      fi
    fi
  fi
  _vg_cb_check_shell "$hook"
}

_vg_cb_check_shell() {
  local hook="$1"
  local lock_file lock_fd status
  lock_file=$(_vg_cb_lock_file "$hook")
  if ! mkdir -p "$(dirname "$lock_file")" 2>/dev/null; then
    printf 'VIBEGUARD ERROR: failed to create circuit breaker lock directory: %s\n' "$(dirname "$lock_file")" >&2
    return 2
  fi
  if ! exec {lock_fd}>"$lock_file"; then
    printf 'VIBEGUARD ERROR: failed to open circuit breaker lock file: %s\n' "$lock_file" >&2
    return 2
  fi
  if (
    _vg_cb_try_flock "$lock_fd" "$lock_file" || exit 2
    trap '_vg_cb_release_flock' EXIT
    _vg_cb_load "$hook" || exit 2
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
          _vg_cb_save "$hook" || exit 2
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
        _vg_cb_save "$hook" || exit 2
        exit 0
        ;;
    esac
  ); then
    status=0
  else
    status=$?
  fi
  exec {lock_fd}>&-
  return "$status"
}

# vg_cb_record_block <hook>
# Records one block/warn event. Trips circuit to OPEN after CB_THRESHOLD consecutive events.
# Protected by an exclusive flock to prevent lost-update races under concurrent access.
vg_cb_record_block() {
  local hook="$1"
  local status
  if _vg_cb_runtime_available; then
    if _vg_cb_runtime_call "record-block" "$hook"; then
      return 0
    else
      status=$?
      if [[ "$status" -ne 127 ]]; then
        return "$status"
      fi
    fi
  fi
  _vg_cb_record_block_shell "$hook"
}

_vg_cb_record_block_shell() {
  local hook="$1"
  local lock_file lock_fd status
  lock_file=$(_vg_cb_lock_file "$hook")
  if ! mkdir -p "$(dirname "$lock_file")" 2>/dev/null; then
    printf 'VIBEGUARD ERROR: failed to create circuit breaker lock directory: %s\n' "$(dirname "$lock_file")" >&2
    return 2
  fi
  if ! exec {lock_fd}>"$lock_file"; then
    printf 'VIBEGUARD ERROR: failed to open circuit breaker lock file: %s\n' "$lock_file" >&2
    return 2
  fi
  if (
    _vg_cb_try_flock "$lock_fd" "$lock_file" || exit 2
    trap '_vg_cb_release_flock' EXIT
    _vg_cb_load "$hook" || exit 2
    CB_BLOCKS=$(( CB_BLOCKS + 1 ))
    CB_LAST_BLOCK=$(_vg_cb_now)

    if [[ "$CB_STATE" == "HALF-OPEN" ]] || [[ "$CB_BLOCKS" -ge "$CB_THRESHOLD" ]]; then
      CB_STATE="OPEN"
      _vg_cb_log "$hook" "circuit-breaker" "warn" \
        "CB tripped OPEN: ${CB_BLOCKS} consecutive blocks, cooldown ${CB_COOLDOWN}s" ""
    fi
    _vg_cb_save "$hook" || exit 2
  ); then
    status=0
  else
    status=$?
  fi
  exec {lock_fd}>&-
  return "$status"
}

# vg_cb_record_pass <hook>
# Records a successful (non-blocking) result. Resets circuit to CLOSED.
# Protected by an exclusive flock to prevent lost-update races under concurrent access.
vg_cb_record_pass() {
  local hook="$1"
  local status
  if _vg_cb_runtime_available; then
    if _vg_cb_runtime_call "record-pass" "$hook"; then
      return 0
    else
      status=$?
      if [[ "$status" -ne 127 ]]; then
        return "$status"
      fi
    fi
  fi
  _vg_cb_record_pass_shell "$hook"
}

_vg_cb_record_pass_shell() {
  local hook="$1"
  local lock_file lock_fd status
  lock_file=$(_vg_cb_lock_file "$hook")
  if ! mkdir -p "$(dirname "$lock_file")" 2>/dev/null; then
    printf 'VIBEGUARD ERROR: failed to create circuit breaker lock directory: %s\n' "$(dirname "$lock_file")" >&2
    return 2
  fi
  if ! exec {lock_fd}>"$lock_file"; then
    printf 'VIBEGUARD ERROR: failed to open circuit breaker lock file: %s\n' "$lock_file" >&2
    return 2
  fi
  if (
    _vg_cb_try_flock "$lock_fd" "$lock_file" || exit 2
    trap '_vg_cb_release_flock' EXIT
    _vg_cb_load "$hook" || exit 2
    if [[ "$CB_STATE" != "CLOSED" ]] || [[ "$CB_BLOCKS" -gt 0 ]]; then
      CB_STATE="CLOSED"
      CB_BLOCKS=0
      CB_LAST_BLOCK=0
      _vg_cb_save "$hook" || exit 2
    fi
  ); then
    status=0
  else
    status=$?
  fi
  exec {lock_fd}>&-
  return "$status"
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

_vg_stop_hook_active_literal_top_level() {
  local input="$1" len i c rest
  local depth=0 in_string=false escape=false current="" key="" after_key=false

  len=${#input}
  i=0
  while [[ "$i" -lt "$len" ]]; do
    c="${input:i:1}"

    if [[ "$in_string" == "true" ]]; then
      if [[ "$escape" == "true" ]]; then
        escape=false
      elif [[ "$c" == "\\" ]]; then
        escape=true
      elif [[ "$c" == '"' ]]; then
        in_string=false
        if [[ "$depth" -eq 1 ]]; then
          key="$current"
          after_key=true
        fi
      elif [[ "$depth" -eq 1 ]]; then
        current="${current}${c}"
      fi
      i=$((i + 1))
      continue
    fi

    case "$c" in
      '"')
        in_string=true
        escape=false
        current=""
        ;;
      "{"|"[")
        depth=$((depth + 1))
        after_key=false
        ;;
      "}"|"]")
        depth=$((depth - 1))
        after_key=false
        ;;
      ":")
        if [[ "$depth" -eq 1 && "$after_key" == "true" && "$key" == "stop_hook_active" ]]; then
          rest="${input:i+1}"
          [[ "$rest" =~ ^[[:space:]]*true([[:space:],}]|$) ]]
          return
        fi
        after_key=false
        ;;
      ",")
        if [[ "$depth" -eq 1 ]]; then
          key=""
          after_key=false
        fi
        ;;
    esac

    i=$((i + 1))
  done

  return 1
}

# vg_stop_hook_active <json_string>
# Returns 0 (true) if the Stop hook input JSON has stop_hook_active == true,
# indicating this invocation was triggered by another Stop hook and should not block.
# Usage:  vg_stop_hook_active "$INPUT" && exit 0
#
# Passes JSON via stdin (pipe) instead of an environment variable to avoid
# hitting execve env-size limits when the input contains a long last_assistant_message.
vg_stop_hook_active() {
  local input="$1" active="" runtime_path=""

  if [[ -n "${_VIBEGUARD_RUNTIME:-}" && -x "${_VIBEGUARD_RUNTIME}" ]]; then
    runtime_path="${_VIBEGUARD_RUNTIME}"
  elif declare -F _vg_config_runtime_path >/dev/null 2>&1; then
    runtime_path="$(_vg_config_runtime_path 2>/dev/null || true)"
  fi

  if [[ -n "$runtime_path" ]]; then
    if active=$(printf '%s' "$input" | "$runtime_path" json-bool-field stop_hook_active 2>/dev/null); then
      [[ "$active" == "true" ]]
      return
    fi
    if active=$(printf '%s' "$input" | "$runtime_path" json-field stop_hook_active 2>/dev/null); then
      [[ "$active" == "true" ]] && _vg_stop_hook_active_literal_top_level "$input"
      return
    fi
  fi

  # Standalone and stale-runtime fallback for unit tests that source this file without log.sh.
  # Require the boolean literal true; truthy strings must not count as active.
  _vg_stop_hook_active_literal_top_level "$input"
}

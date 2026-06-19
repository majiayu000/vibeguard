#!/usr/bin/env bash
# VibeGuard PostToolUse(Write) Hook
#
# Review-only duplicate/stub/U-16 scan after Write. The parser, project scan,
# warning construction, and log append are owned by vibeguard-runtime.

set -euo pipefail

source "$(dirname "$0")/log.sh"
vg_start_timer
export VIBEGUARD_HOOK_START_MS="${_VG_START_MS:-}"

INPUT=$(cat)

_vg_post_write_error_log_path() {
  if [[ -n "${VIBEGUARD_LOG_FILE:-}" && -d "${VIBEGUARD_LOG_FILE}.lock.d" ]]; then
    printf '%s' "$VIBEGUARD_LOG_FILE"
  elif [[ -n "${VIBEGUARD_LOG_DIR:-}" && -d "${VIBEGUARD_LOG_DIR}/events.jsonl.lock.d" ]]; then
    printf '%s/events.jsonl' "$VIBEGUARD_LOG_DIR"
  else
    printf '%s' "${VIBEGUARD_LOG_FILE:-unknown}"
  fi
}

vg_config_get_int_result _VG_U16_BASE_LIMIT VG_U16_LIMIT u16.limit 800
vg_u16_warn_limit_result _VG_U16_WARN_LIMIT "$_VG_U16_BASE_LIMIT"
_VG_SCAN_MAX_FILES="${VG_SCAN_MAX_FILES:-5000}"
_VG_SCAN_MAX_DEFS="${VG_SCAN_MAX_DEFS:-20}"
_VG_SCAN_MATCH_LIMIT="${VG_SCAN_MATCH_LIMIT:-5}"

_VG_RUNTIME_ERR="$(mktemp)"
_vg_cleanup_runtime_err() {
  local status=$?
  if ! rm -f "$_VG_RUNTIME_ERR" 2>/dev/null; then
    printf 'VIBEGUARD ERROR: failed to remove post-write runtime stderr temp file\n' >&2
  fi
  trap - EXIT
  return "$status"
}
trap _vg_cleanup_runtime_err EXIT

if printf '%s' "$INPUT" | "$_VIBEGUARD_RUNTIME" post-write-check \
  "$_VG_U16_BASE_LIMIT" \
  "$_VG_U16_WARN_LIMIT" \
  "$_VG_SCAN_MAX_FILES" \
  "$_VG_SCAN_MAX_DEFS" \
  "$_VG_SCAN_MATCH_LIMIT" \
  "$VIBEGUARD_LOG_FILE" \
  2>"$_VG_RUNTIME_ERR"; then
  exit 0
fi

_VG_RUNTIME_MSG="$(head -c 300 "$_VG_RUNTIME_ERR" 2>/dev/null || true)"
[[ -n "$_VG_RUNTIME_MSG" ]] || _VG_RUNTIME_MSG="unknown runtime error"
_VG_FAILURE_KIND="runtime"
_VG_RECOVERY="bash scripts/hook-health.sh 24"
_VG_ERROR_LOG_PATH="$(_vg_post_write_error_log_path)"
if [[ "$_VG_ERROR_LOG_PATH" != "unknown" && -d "${_VG_ERROR_LOG_PATH}.lock.d" ]]; then
  _VG_FAILURE_KIND="lock"
  _VG_RECOVERY="if no VibeGuard hook is active, run: rmdir \"${_VG_ERROR_LOG_PATH}.lock.d\""
fi
_VG_INTERNAL_CONTEXT="VIBEGUARD internal error [VG-INTERNAL-POST-WRITE-RUNTIME]: hook=post-write-guard tool=Write failure_kind=${_VG_FAILURE_KIND} mode=warn project=${VIBEGUARD_PROJECT_HASH:-unknown} session=${VIBEGUARD_SESSION_ID:-unknown} log_path=${_VG_ERROR_LOG_PATH} recovery=${_VG_RECOVERY} detail=post-write runtime check failed: ${_VG_RUNTIME_MSG}"
if ! vg_log "post-write-guard" "Write" "warn" "vibeguard_internal_error failure_kind=${_VG_FAILURE_KIND} code=VG-INTERNAL-POST-WRITE-RUNTIME: $_VG_RUNTIME_MSG" ""; then
  printf 'VIBEGUARD ERROR: failed to log post-write runtime failure\n' >&2
fi

_VG_INTERNAL_CONTEXT="${_VG_INTERNAL_CONTEXT//\\/\\\\}"
_VG_INTERNAL_CONTEXT="${_VG_INTERNAL_CONTEXT//\"/\\\"}"
_VG_INTERNAL_CONTEXT="${_VG_INTERNAL_CONTEXT//$'\n'/\\n}"
_VG_INTERNAL_CONTEXT="${_VG_INTERNAL_CONTEXT//$'\t'/\\t}"
printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$_VG_INTERNAL_CONTEXT"

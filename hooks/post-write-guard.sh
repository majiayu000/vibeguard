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

_VG_U16_BASE_LIMIT=$(vg_config_get_int VG_U16_LIMIT u16.limit 800)
_VG_U16_WARN_LIMIT=$(vg_u16_warn_limit "$_VG_U16_BASE_LIMIT")
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
if ! vg_log "post-write-guard" "Write" "warn" "runtime post-write-check failed; fail-closed: $_VG_RUNTIME_MSG" ""; then
  printf 'VIBEGUARD ERROR: failed to log post-write runtime failure\n' >&2
fi

cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "VIBEGUARD ERROR: post-write runtime check failed; reporting visibly instead of silently passing."
  }
}
EOF

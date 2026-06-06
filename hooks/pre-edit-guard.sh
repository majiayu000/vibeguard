#!/usr/bin/env bash
# VibeGuard PreToolUse(Edit) Hook
#
# Anti-hallucination check before editing files:
# - Detect whether the edited file exists (prevents AI from editing non-existent file paths)
# - Check if old_string is actually in the file (to prevent AI hallucinating editing content)

set -euo pipefail

source "$(dirname "$0")/log.sh"

INPUT=$(cat)

# Base U-16 limit resolved from env var > ~/.vibeguard/config.json > built-in 800.
_U16_BASE_LIMIT=$(vg_config_get_int VG_U16_LIMIT u16.limit 800)
_U16_WARN_LIMIT=$(vg_u16_warn_limit "$_U16_BASE_LIMIT")
if [[ -n "${_VIBEGUARD_RUNTIME:-}" ]]; then
  _VG_FAST_RESULT=$(printf '%s' "$INPUT" \
    | "$_VIBEGUARD_RUNTIME" pre-edit-check "$_U16_BASE_LIMIT" "$_U16_WARN_LIMIT" "$VIBEGUARD_LOG_FILE" \
    2>/dev/null || true)
  _VG_FAST_STATUS="${_VG_FAST_RESULT%%$'\n'*}"
  case "$_VG_FAST_STATUS" in
    SKIP)
      exit 0
      ;;
    FAST_LOGGED)
      exit 0
      ;;
    FAST_OUTPUT)
      _VG_FAST_PAYLOAD="${_VG_FAST_RESULT#*$'\n'}"
      [[ "$_VG_FAST_PAYLOAD" != "$_VG_FAST_RESULT" ]] && printf '%s\n' "$_VG_FAST_PAYLOAD"
      exit 0
      ;;
  esac
fi

vg_log "pre-edit-guard" "Edit" "block" "pre-edit runtime check failed; fail-closed" ""
vg_json_output_kv decision block reason "VIBEGUARD interception: runtime pre-edit-check failed or returned an unsupported status; fail-closed."
exit 0

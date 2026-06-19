#!/usr/bin/env bash
# VibeGuard PreToolUse(Edit) Hook
#
# Anti-hallucination check before editing files:
# - Detect whether the edited file exists (prevents AI from editing non-existent file paths)
# - Check if old_string is actually in the file (to prevent AI hallucinating editing content)

set -euo pipefail

source "$(dirname "$0")/log.sh"

INPUT=$(cat)

vg_pre_edit_failure_kind() {
  if [[ -n "${VIBEGUARD_LOG_FILE:-}" && -d "${VIBEGUARD_LOG_FILE}.lock.d" ]]; then
    printf 'lock'
  else
    printf 'runtime'
  fi
}

vg_pre_edit_internal_message() {
  local code="$1"
  local failure_kind="$2"
  local mode="$3"
  local runtime_detail="$4"
  local log_path="${VIBEGUARD_LOG_FILE:-unknown}"
  local lock_path="${log_path}.lock.d"
  local session="${VIBEGUARD_SESSION_ID:-unknown}"
  local project="${VIBEGUARD_PROJECT_HASH:-unknown}"
  local recovery="bash scripts/hook-health.sh 24"

  if [[ "$failure_kind" == "lock" ]]; then
    recovery="if no VibeGuard hook is active, run: rmdir \"${lock_path}\""
  fi

  printf 'VIBEGUARD internal error [%s]: hook=pre-edit-guard tool=Edit failure_kind=%s mode=%s project=%s session=%s log_path=%s recovery=%s detail=%s' \
    "$code" "$failure_kind" "$mode" "$project" "$session" "$log_path" "$recovery" "${runtime_detail:-unknown}"
}

vg_pre_edit_visible_internal_warning() {
  local code="$1"
  local failure_kind="$2"
  local runtime_detail="$3"
  local msg
  msg="$(vg_pre_edit_internal_message "$code" "$failure_kind" "allow" "$runtime_detail")"
  vg_log "pre-edit-guard" "Edit" "warn" "vibeguard_internal_error failure_kind=${failure_kind} code=${code}" "" >/dev/null 2>&1 || true
  printf '%s\n' "$msg" | "$_VIBEGUARD_RUNTIME" hook-context PreToolUse
}

vg_pre_edit_visible_internal_block() {
  local code="$1"
  local failure_kind="$2"
  local runtime_detail="$3"
  local msg
  msg="$(vg_pre_edit_internal_message "$code" "$failure_kind" "block" "$runtime_detail")"
  vg_log "pre-edit-guard" "Edit" "block" "vibeguard_internal_error failure_kind=${failure_kind} code=${code}" "" >/dev/null 2>&1 || true
  vg_json_output_kv decision block reason "$msg"
}

# Base U-16 limit resolved from env var > ~/.vibeguard/config.json > built-in 800.
vg_config_get_int_result _U16_BASE_LIMIT VG_U16_LIMIT u16.limit 800
vg_u16_warn_limit_result _U16_WARN_LIMIT "$_U16_BASE_LIMIT"
if [[ -n "${_VIBEGUARD_RUNTIME:-}" ]]; then
  _VG_PRE_EDIT_ERR="$(mktemp)"
  _vg_pre_edit_cleanup() {
    rm -f "$_VG_PRE_EDIT_ERR" 2>/dev/null || true
  }
  trap _vg_pre_edit_cleanup EXIT
  _VG_FAST_RESULT=""
  _VG_FAST_RC=0
  if _VG_FAST_RESULT=$(printf '%s' "$INPUT" \
    | "$_VIBEGUARD_RUNTIME" pre-edit-check "$_U16_BASE_LIMIT" "$_U16_WARN_LIMIT" "$VIBEGUARD_LOG_FILE" \
    2>"$_VG_PRE_EDIT_ERR"); then
    _VG_FAST_RC=0
  else
    _VG_FAST_RC=$?
  fi
  _VG_FAST_DETAIL="$(head -c 300 "$_VG_PRE_EDIT_ERR" 2>/dev/null || true)"
  _VG_FAST_STATUS="${_VG_FAST_RESULT%%$'\n'*}"
  if [[ "$_VG_FAST_RC" -eq 0 ]]; then
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
      FALLBACK)
        vg_pre_edit_visible_internal_warning "VG-INTERNAL-LOG-APPEND" "$(vg_pre_edit_failure_kind)" "pre-edit validation passed but event log append failed"
        exit 0
        ;;
    esac
  fi
fi

if [[ "${_VG_FAST_RC:-0}" -ne 0 ]]; then
  vg_pre_edit_visible_internal_block "VG-INTERNAL-PRE-EDIT-RUNTIME" "$(vg_pre_edit_failure_kind)" "${_VG_FAST_DETAIL:-runtime pre-edit-check failed}"
else
  vg_pre_edit_visible_internal_block "VG-INTERNAL-PRE-EDIT-STATUS" "schema" "unsupported pre-edit-check status: ${_VG_FAST_STATUS:-empty}"
fi
exit 0

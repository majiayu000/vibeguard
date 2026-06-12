#!/usr/bin/env bash
# VibeGuard PreToolUse(Write) Hook
#
# Grading strategy:
# - Edit existing file → Release
# - New configuration/document/test file → Release
# - Create a new source code file (.rs/.py/.ts/.js/.go/.jsx/.tsx) → intercept (requires searching first and then writing)
#
#Default warn mode: remind to search first and then write (L1 constraint is covered by PostToolUse repeated detection)
# Set VIBEGUARD_WRITE_MODE=block to upgrade to hard blocking mode

set -euo pipefail

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/circuit-breaker.sh"
vg_start_timer

_pass_and_exit() {
  if ! vg_cb_record_pass "pre-write-guard"; then
    vg_log "pre-write-guard" "Write" "block" "Circuit breaker state error; fail-closed" ""
    vg_json_output_kv decision block reason "VIBEGUARD interception: pre-write circuit breaker state could not be updated; fail-closed instead of silently continuing."
  fi
  exit 0
}

INPUT=$(cat)

vg_config_get_int_result _U16_BASE_LIMIT VG_U16_LIMIT u16.limit 800
vg_u16_warn_limit_result _U16_WARN_LIMIT "$_U16_BASE_LIMIT"
if ! CHECK_RESULT=$(printf '%s' "$INPUT" | "$_VIBEGUARD_RUNTIME" pre-write-check "$_U16_BASE_LIMIT" "$_U16_WARN_LIMIT" 2>/dev/null); then
  vg_log "pre-write-guard" "Write" "block" "vibeguard-runtime pre-write-check failed; fail-closed" ""
  vg_json_output_kv decision block reason "VIBEGUARD interception: runtime pre-write-check failed; fail-closed."
  exit 0
fi

CHECK_STATUS="${CHECK_RESULT%%$'\n'*}"
_CHECK_REST="${CHECK_RESULT#*$'\n'}"
FILE_PATH="${_CHECK_REST%%$'\n'*}"
[[ "$FILE_PATH" == "$CHECK_RESULT" ]] && FILE_PATH=""

if [[ "$CHECK_STATUS" == "MALFORMED" ]]; then
  vg_log "pre-write-guard" "Write" "block" "Malformed hook input" ""
  cat <<'EOF'
{
  "decision": "block",
  "reason": "VIBEGUARD interception: malformed PreToolUse(Write) hook input. The write request could not be validated, so it was blocked instead of being treated as a safe skip."
}
EOF
  exit 0
fi

if [[ "$CHECK_STATUS" == "PASS" || -z "$FILE_PATH" ]]; then
  _pass_and_exit
fi

if [[ "$CHECK_STATUS" == "W12" ]]; then
  vg_log "pre-write-guard" "Write" "block" "Test Infrastructure File Guard (W-12)" "$FILE_PATH"
  cat <<'EOF'
{
  "decision": "block",
  "reason": "[W-12] [block] [this-edit] OBSERVATION: writing to test infrastructure file blocked (conftest.py/jest.config/pytest.ini/.coveragerc/babel.config)\nFIX: Fix the production code that is failing — do not manipulate test framework configuration"
}
EOF
  exit 0
fi

if [[ "$CHECK_STATUS" == "U16_BLOCK" ]]; then
  _CHECK_REST="${_CHECK_REST#*$'\n'}"
  _U16_LINES="${_CHECK_REST%%$'\n'*}"
  _CHECK_REST="${_CHECK_REST#*$'\n'}"
  _U16_LIM="${_CHECK_REST%%$'\n'*}"
  vg_log "pre-write-guard" "Write" "block" "U-16 file size: ${_U16_LINES} > ${_U16_LIM}" "$FILE_PATH"
  cat <<BLOCK_EOF
{
  "decision": "block",
  "reason": "VIBEGUARD [U-16] block: writing ${FILE_PATH##*/} with ${_U16_LINES} lines exceeds the ${_U16_LIM}-line limit. Split into focused submodules first. Do NOT proceed with this write."
}
BLOCK_EOF
  exit 0
fi

_U16_SOURCE_NEW_LINES=""
_U16_SOURCE_NEW_WARN=""
_U16_SOURCE_NEW_LIMIT=""

if [[ "$CHECK_STATUS" == "U16_WARN" || "$CHECK_STATUS" == "U16_WARN_SOURCE_NEW" ]]; then
  _CHECK_REST="${_CHECK_REST#*$'\n'}"
  _U16_LINES="${_CHECK_REST%%$'\n'*}"
  _CHECK_REST="${_CHECK_REST#*$'\n'}"
  _U16_WARN="${_CHECK_REST%%$'\n'*}"
  _CHECK_REST="${_CHECK_REST#*$'\n'}"
  _U16_LIM="${_CHECK_REST%%$'\n'*}"
  vg_log "pre-write-guard" "Write" "warn" "U-16 file size advisory: ${_U16_LINES} > ${_U16_WARN}" "$FILE_PATH"
  if [[ "$CHECK_STATUS" == "U16_WARN_SOURCE_NEW" ]]; then
    _U16_SOURCE_NEW_LINES="$_U16_LINES"
    _U16_SOURCE_NEW_WARN="$_U16_WARN"
    _U16_SOURCE_NEW_LIMIT="$_U16_LIM"
    CHECK_STATUS="SOURCE_NEW"
  else
    cat <<EOF | "$_VIBEGUARD_RUNTIME" hook-context PreToolUse
VIBEGUARD [U-16] [advisory] [this-file] OBSERVATION: writing ${FILE_PATH##*/} with ${_U16_LINES} lines exceeds the ${_U16_WARN}-line typical range but stays under the ${_U16_LIM}-line hard limit
SCOPE: keep the current change localized; plan a split if this file keeps growing
ACTION: NONE — advisory only, continue without acknowledgement
EOF
    exit 0
  fi
fi

if [[ "$CHECK_STATUS" != "SOURCE_NEW" ]]; then
  _pass_and_exit
fi

# --- Source code files: reminder to search first and then write ---
# Default warn (reminder), set VIBEGUARD_WRITE_MODE=block to upgrade to hard interception.
#
# Circuit breaker (warn mode): after CB_THRESHOLD consecutive notices in the same
# session the circuit OPENs and subsequent writes pass silently. This prevents
# 6-file batch writes from injecting 6 redundant advisories. Block mode does not
# use the circuit breaker so hard rejections are never silenced.
vg_config_get_str_result MODE VIBEGUARD_WRITE_MODE write_mode warn
case "$MODE" in
  block|warn) ;;
  *) MODE="warn" ;;
esac

if [[ "$MODE" == "block" ]]; then
  vg_log "pre-write-guard" "Write" "block" "New source code file not searched" "$FILE_PATH"
  cat <<'EOF'
{
  "decision": "block",
  "reason": "VIBEGUARD [L1] [block] [this-edit] OBSERVATION: new source file creation blocked — search not performed before write\nSCOPE: search required before retry — use Grep for functions/classes/structs, Glob for same-named files\nACTION: REVIEW"
}
EOF
else
  # Escalation: count prior new-source attempts in this session. After N hits
  # the agent has demonstrably ignored the warning, so the next attempt is
  # blocked. Threshold is configurable; set to 0 to disable escalation.
  vg_config_get_int_result ESCALATE_THRESHOLD VIBEGUARD_PRE_WRITE_ESCALATE_THRESHOLD write_escalate_threshold 5
  PRIOR_SOURCE_NEW_COUNT=0
  if [[ "$ESCALATE_THRESHOLD" -gt 0 && -f "$VIBEGUARD_LOG_FILE" ]]; then
    PRIOR_SOURCE_NEW_COUNT=$(tail -500 "$VIBEGUARD_LOG_FILE" \
      | "$_VIBEGUARD_RUNTIME" reason-count "$VIBEGUARD_SESSION_ID" "pre-write-guard" "New source file attempt" \
      2>/dev/null || echo 0)
    PRIOR_SOURCE_NEW_COUNT="${PRIOR_SOURCE_NEW_COUNT:-0}"
  fi

  if [[ "$ESCALATE_THRESHOLD" -gt 0 && "$PRIOR_SOURCE_NEW_COUNT" -ge "$ESCALATE_THRESHOLD" ]]; then
    vg_log "pre-write-guard" "Write" "escalate" "L1 escalation after ${PRIOR_SOURCE_NEW_COUNT} unheeded source-new attempts" "$FILE_PATH"
    cat <<EOF
{
  "decision": "block",
  "reason": "VIBEGUARD [L1] [block] [escalation] OBSERVATION: ${PRIOR_SOURCE_NEW_COUNT} new source file attempts in this session went unheeded\nSCOPE: pause new file creation — run Grep for similar function/class names and Glob for same-named files in this repo before any further Write\nACTION: REVIEW — confirm no duplicate exists; after manual verification start a new session, raise VIBEGUARD_PRE_WRITE_ESCALATE_THRESHOLD, or export VIBEGUARD_PRE_WRITE_ESCALATE_THRESHOLD=0 to disable escalation for this session"
}
EOF
    exit 0
  fi

  vg_log "pre-write-guard" "Write" "warn" "New source file attempt" "$FILE_PATH"

  CB_STATUS=0
  if vg_cb_check "pre-write-guard"; then
    CB_STATUS=0
  else
    CB_STATUS=$?
  fi

  if [[ "$CB_STATUS" -eq 0 ]]; then
    vg_log "pre-write-guard" "Write" "warn" "New source file reminder" "$FILE_PATH"
    if ! vg_cb_record_block "pre-write-guard"; then
      vg_log "pre-write-guard" "Write" "block" "Circuit breaker state error; fail-closed" "$FILE_PATH"
      vg_json_output_kv decision block reason "VIBEGUARD interception: pre-write circuit breaker state could not be persisted; fail-closed instead of silently continuing."
      exit 0
    fi
    if [[ -n "$_U16_SOURCE_NEW_LINES" ]]; then
      cat <<EOF | "$_VIBEGUARD_RUNTIME" hook-context PreToolUse
VIBEGUARD [U-16] [advisory] [this-file] OBSERVATION: writing ${FILE_PATH##*/} with ${_U16_SOURCE_NEW_LINES} lines exceeds the ${_U16_SOURCE_NEW_WARN}-line typical range but stays under the ${_U16_SOURCE_NEW_LIMIT}-line hard limit
SCOPE: keep the current change localized; plan a split if this file keeps growing
ACTION: NONE — advisory only, continue without acknowledgement
---
VIBEGUARD [L1] [advisory] [this-edit] OBSERVATION: new source file detected — search for similar implementation before adding duplicates
SCOPE: if not yet checked, consider Grep for functions/classes/structs and Glob for same-named files
ACTION: NONE — advisory only, continue without acknowledgement
EOF
    else
      cat <<'EOF' | "$_VIBEGUARD_RUNTIME" hook-context PreToolUse
VIBEGUARD [L1] [advisory] [this-edit] OBSERVATION: new source file detected — search for similar implementation before adding duplicates
SCOPE: if not yet checked, consider Grep for functions/classes/structs and Glob for same-named files
ACTION: NONE — advisory only, continue without acknowledgement
EOF
    fi
  elif [[ "$CB_STATUS" -eq 1 ]]; then
    : # Circuit OPEN: silent pass (vg_cb_check already logged the auto-pass).
  else
    vg_log "pre-write-guard" "Write" "block" "Circuit breaker state error; fail-closed" "$FILE_PATH"
    vg_json_output_kv decision block reason "VIBEGUARD interception: pre-write circuit breaker state could not be read; fail-closed instead of silently auto-passing."
    exit 0
  fi
fi

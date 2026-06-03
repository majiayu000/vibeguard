#!/usr/bin/env bash
# VibeGuard PreToolUse(Bash) Hook
#
# Rust classifies Bash input; this shell wrapper preserves hook logging,
# package-tool availability checks, and the git-commit pre-commit bridge.
# Runtime malformed input contract: invalid Bash hook input JSON; fail-closed.

set -euo pipefail

source "$(dirname "$0")/log.sh"
vg_start_timer

INPUT=$(cat)
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
VIBEGUARD_ROOT="${VIBEGUARD_DIR:-$(cd "$HOOK_DIR/.." && pwd)}"

fail_closed_runtime() {
  local reason="$1"
  local detail="${2:-}"
  vg_log "pre-bash-guard" "Bash" "block" "$reason" "$detail"
  vg_json_output_kv decision block reason "VIBEGUARD interception: ${reason}"
  exit 0
}

pre_bash_required_field() {
  local field="$1"
  printf '%s' "$PRE_BASH_BODY" | vg_json_field_strict "$field"
}

runtime_err=$(mktemp "${TMPDIR:-/tmp}/vibeguard-pre-bash.XXXXXX") || \
  fail_closed_runtime "pre-bash-check stderr capture could not be created" ""
if PRE_BASH_RESULT=$(printf '%s' "$INPUT" | "$_VIBEGUARD_RUNTIME" pre-bash-check "$VIBEGUARD_ROOT" 2>"$runtime_err"); then
  runtime_status=0
else
  runtime_status=$?
fi
if ! runtime_stderr=$(cat "$runtime_err"); then
  if ! rm -f "$runtime_err"; then
    printf 'VIBEGUARD ERROR: failed to remove pre-bash stderr capture: %s\n' "$runtime_err" >&2
  fi
  fail_closed_runtime "pre-bash-check stderr capture could not be read" ""
fi
if ! rm -f "$runtime_err"; then
  fail_closed_runtime "pre-bash-check stderr capture could not be removed" ""
fi
if [[ "$runtime_status" -ne 0 ]]; then
  fail_closed_runtime "pre-bash-check runtime failed: ${runtime_stderr:-exit $runtime_status}" ""
fi
if [[ -n "$runtime_stderr" ]]; then
  fail_closed_runtime "pre-bash-check runtime wrote stderr: $runtime_stderr" ""
fi

PRE_BASH_TOKEN="${PRE_BASH_RESULT%%$'\n'*}"
PRE_BASH_BODY="${PRE_BASH_RESULT#*$'\n'}"
[[ "$PRE_BASH_BODY" == "$PRE_BASH_RESULT" ]] && PRE_BASH_BODY="{}"

case "$PRE_BASH_TOKEN" in
  EMPTY)
    exit 0
    ;;
  BLOCK)
    if ! LOG_REASON=$(pre_bash_required_field log_reason) \
        || ! DETAIL=$(pre_bash_required_field detail) \
        || ! HOOK_OUTPUT=$(pre_bash_required_field output); then
      fail_closed_runtime "pre-bash-check emitted invalid BLOCK payload" ""
    fi
    vg_log "pre-bash-guard" "Bash" "block" "$LOG_REASON" "$DETAIL"
    printf '%s\n' "$HOOK_OUTPUT"
    exit 0
    ;;
  WARN)
    if ! LOG_REASON=$(pre_bash_required_field log_reason) \
        || ! DETAIL=$(pre_bash_required_field detail) \
        || ! HOOK_OUTPUT=$(pre_bash_required_field output); then
      fail_closed_runtime "pre-bash-check emitted invalid WARN payload" ""
    fi
    vg_log "pre-bash-guard" "Bash" "warn" "$LOG_REASON" "$DETAIL"
    printf '%s\n' "$HOOK_OUTPUT"
    exit 0
    ;;
  CORRECTION)
    if ! COMMAND=$(pre_bash_required_field command) \
        || ! CORRECTED=$(pre_bash_required_field corrected) \
        || ! HOOK_OUTPUT=$(pre_bash_required_field output); then
      fail_closed_runtime "pre-bash-check emitted invalid CORRECTION payload" ""
    fi
    target_tool="${CORRECTED%% *}"
    if ! command -v "$target_tool" &>/dev/null; then
      vg_log "pre-bash-guard" "Bash" "pass" "pkg-rewrite skipped (${target_tool} not found)" "${COMMAND:0:120}"
      exit 0
    fi
    if [[ "$CORRECTED" == uv\ pip\ install* ]] \
        && [[ -z "${VIRTUAL_ENV:-}" ]] && [[ ! -d ".venv" ]]; then
      vg_log "pre-bash-guard" "Bash" "pass" "pkg-rewrite skipped (no active venv for uv pip)" "${COMMAND:0:120}"
      exit 0
    fi
    vg_log "pre-bash-guard" "Bash" "correction" "package manager auto-rewrite" "${COMMAND:0:120} → $CORRECTED"
    printf '%s\n' "$HOOK_OUTPUT"
    exit 0
    ;;
  PASS)
    if ! COMMAND=$(pre_bash_required_field command) \
        || ! PRECOMMIT=$(pre_bash_required_field precommit); then
      fail_closed_runtime "pre-bash-check emitted invalid PASS payload" ""
    fi
    if [[ "$PRECOMMIT" == "true" ]]; then
      PRECOMMIT_SCRIPT="${HOOK_DIR}/pre-commit-guard.sh"
      if [[ -f "$PRECOMMIT_SCRIPT" ]]; then
        PRECOMMIT_EXIT=0
        PRECOMMIT_OUTPUT=$(VIBEGUARD_DIR="$VIBEGUARD_ROOT" bash "$PRECOMMIT_SCRIPT" 2>&1) || PRECOMMIT_EXIT=$?
        if [[ $PRECOMMIT_EXIT -ne 0 ]]; then
          vg_log "pre-bash-guard" "Bash" "block" "pre-commit check failed" "$COMMAND"
          vg_json_output_kv decision block reason "VIBEGUARD Pre-Commit 检查失败。请根据上方错误信息修复问题后重新提交。禁止使用环境变量绕过。

$PRECOMMIT_OUTPUT"
          exit 0
        fi
      fi
    fi
    vg_log "pre-bash-guard" "Bash" "pass" "" "$COMMAND"
    exit 0
    ;;
  *)
    fail_closed_runtime "pre-bash-check emitted unexpected token: $PRE_BASH_TOKEN" ""
    ;;
esac

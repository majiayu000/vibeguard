#!/usr/bin/env bash
# VibeGuard Codex Hook Wrapper — Adapt the output format of Codex CLI
#
# The I/O formats of Codex CLI hooks and Claude Code hooks are different:
# - PreToolUse block: Codex requires hookSpecificOutput.permissionDecision="deny"
# - PreToolUse warn: Codex uses systemMessage
# - updatedInput (correction): Codex CLI cannot apply it directly, emit an explicit note instead
# - SessionStart/Stop: The format is basically compatible, direct transparent transmission
#
# Usage: bash run-hook-codex.sh <hook-script-name> [args...]

set -euo pipefail

export VIBEGUARD_AGENT_TYPE="codex"
export VIBEGUARD_CLI="codex"

HOOK_NAME="${1:?Usage: run-hook-codex.sh <hook-name>}"
shift

# Codex path is namespaced-only. Non-namespaced hook names are unsupported.
if [[ "${HOOK_NAME}" != vibeguard-* ]]; then
  exit 0
fi

INSTALLED_DIR="${HOME}/.vibeguard/installed/hooks"
HOOK_PATH="${INSTALLED_DIR}/${HOOK_NAME}"

if [[ ! -d "$INSTALLED_DIR" ]]; then
  REPO_PATH_FILE="${HOME}/.vibeguard/repo-path"
  if [[ ! -f "$REPO_PATH_FILE" ]]; then
    exit 0
  fi
  REPO_DIR=$(<"$REPO_PATH_FILE")
  HOOK_PATH="${REPO_DIR}/hooks/${HOOK_NAME}"
fi

if [[ ! -f "$HOOK_PATH" ]]; then
  exit 0
fi

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

INPUT=$(cat)

HOOK_OUTPUT=""
HOOK_EXIT=0
HOOK_OUTPUT=$(printf '%s' "$INPUT" | bash "$HOOK_PATH" "$@" 2>/dev/null) || HOOK_EXIT=$?

EVENT_NAME=$(printf '%s' "$INPUT" | python3 -c "
import json, sys
try:
    print(json.load(sys.stdin).get('hook_event_name', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")

if [[ $HOOK_EXIT -ne 0 ]]; then
  if [[ "$EVENT_NAME" == "PreToolUse" ]]; then
    python3 - <<'PY'
import json
print(json.dumps({
    'hookSpecificOutput': {
        'hookEventName': 'PreToolUse',
        'permissionDecision': 'deny',
        'permissionDecisionReason': 'VIBEGUARD hook failed: wrapped hook exited nonzero.'
    }
}, ensure_ascii=False))
PY
    exit "$HOOK_EXIT"
  fi
  exit 0
fi

if [[ -z "$HOOK_OUTPUT" ]]; then
  exit 0
fi

if [[ "$EVENT_NAME" == "PreToolUse" ]]; then
  pretool_status=0
  pretool_output=$(printf '%s' "$HOOK_OUTPUT" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print(json.dumps({
        'hookSpecificOutput': {
            'hookEventName': 'PreToolUse',
            'permissionDecision': 'deny',
            'permissionDecisionReason': 'VIBEGUARD hook failed: wrapped hook produced invalid JSON.'
        }
    }, ensure_ascii=False))
    sys.exit(3)

decision = data.get('decision', 'pass')
reason = data.get('reason', '')
updated = data.get('updatedInput')

if decision == 'block':
    print(json.dumps({
        'hookSpecificOutput': {
            'hookEventName': 'PreToolUse',
            'permissionDecision': 'deny',
            'permissionDecisionReason': reason
        }
    }, ensure_ascii=False))
elif decision == 'warn':
    print(json.dumps({'systemMessage': reason}, ensure_ascii=False))
elif decision == 'allow' and isinstance(updated, dict):
    command = updated.get('command')
    if isinstance(command, str) and command:
        print(json.dumps({
            'systemMessage': (
                'VIBEGUARD note: Codex CLI hooks cannot auto-apply command rewrites. '
                'Suggested command: ' + command
            )
        }, ensure_ascii=False))
") || pretool_status=$?
  if [[ ${pretool_status} -ne 0 ]]; then
    if [[ -n "$pretool_output" ]]; then
      printf '%s\n' "$pretool_output"
    else
      python3 - <<'PY'
import json
print(json.dumps({
    'hookSpecificOutput': {
        'hookEventName': 'PreToolUse',
        'permissionDecision': 'deny',
        'permissionDecisionReason': 'VIBEGUARD hook failed: wrapped hook output could not be adapted.'
    }
}, ensure_ascii=False))
PY
    fi
    exit "$pretool_status"
  fi
  if [[ -n "$pretool_output" ]]; then
    printf '%s\n' "$pretool_output"
  fi
elif [[ "$EVENT_NAME" == "PostToolUse" ]]; then
  echo "$HOOK_OUTPUT" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

decision = data.get('decision', 'pass')
reason = data.get('reason', '')

if decision in ('block', 'escalate'):
    print(json.dumps({
        'decision': 'block',
        'reason': reason,
        'hookSpecificOutput': {
            'hookEventName': 'PostToolUse',
            'additionalContext': reason
        }
    }, ensure_ascii=False))
elif decision == 'warn':
    print(json.dumps({'systemMessage': reason}, ensure_ascii=False))
" 2>/dev/null
else
  # SessionStart / Stop / UserPromptSubmit — direct transparent transmission
  echo "$HOOK_OUTPUT"
fi

exit 0

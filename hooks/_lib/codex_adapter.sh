#!/usr/bin/env bash
# Shared Codex hook output adapter.

codex_event_name() {
  local input="$1"
  CODEX_INPUT="${input}" python3 - <<'PY'
import json
import os

try:
    print(json.loads(os.environ.get("CODEX_INPUT", "")).get("hook_event_name", ""))
except Exception:
    print("")
PY
}

codex_pretool_deny() {
  local reason="$1"
  CODEX_REASON="${reason}" python3 - <<'PY'
import json
import os

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": os.environ.get("CODEX_REASON", ""),
    }
}, ensure_ascii=False))
PY
}

codex_adapt_pretool() {
  local hook_output="$1"
  CODEX_HOOK_OUTPUT="${hook_output}" python3 - <<'PY'
import json
import os
import sys

try:
    data = json.loads(os.environ.get("CODEX_HOOK_OUTPUT", ""))
except Exception:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": "VIBEGUARD hook failed: wrapped hook produced invalid JSON.",
        }
    }, ensure_ascii=False))
    sys.exit(3)

decision = data.get("decision", "pass")
reason = data.get("reason", "")
updated = data.get("updatedInput")

if decision == "block":
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }, ensure_ascii=False))
elif decision == "warn":
    print(json.dumps({"systemMessage": reason}, ensure_ascii=False))
elif decision == "allow" and isinstance(updated, dict):
    command = updated.get("command")
    if isinstance(command, str) and command:
        print(json.dumps({
            "systemMessage": (
                "VIBEGUARD note: Codex CLI hooks cannot auto-apply command rewrites. "
                "Suggested command: " + command
            )
        }, ensure_ascii=False))
PY
}

codex_adapt_posttool() {
  local hook_output="$1"
  CODEX_HOOK_OUTPUT="${hook_output}" python3 - <<'PY'
import json
import os
import sys

try:
    data = json.loads(os.environ.get("CODEX_HOOK_OUTPUT", ""))
except Exception:
    sys.exit(3)

decision = data.get("decision", "pass")
reason = data.get("reason", "")

if decision in ("block", "escalate"):
    print(json.dumps({
        "decision": "block",
        "reason": reason,
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": reason,
        },
    }, ensure_ascii=False))
elif decision == "warn":
    print(json.dumps({"systemMessage": reason}, ensure_ascii=False))
PY
}

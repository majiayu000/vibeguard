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

codex_permission_deny() {
  local reason="$1"
  CODEX_REASON="${reason}" python3 - <<'PY'
import json
import os

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PermissionRequest",
        "decision": {
            "behavior": "deny",
            "message": os.environ.get("CODEX_REASON", ""),
        },
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
hook_specific = data.get("hookSpecificOutput")
native_output = isinstance(hook_specific, dict) or "systemMessage" in data

def native_pretool_output() -> dict:
    output = {}
    if "systemMessage" in data:
        output["systemMessage"] = data["systemMessage"]
    if isinstance(hook_specific, dict):
        output["hookSpecificOutput"] = dict(hook_specific)
    return output

if native_output and decision == "pass" and updated is None:
    passthrough = native_pretool_output()
    if passthrough:
        print(json.dumps(passthrough, ensure_ascii=False))
    sys.exit(0)

if decision == "block":
    hook_specific = data.get("hookSpecificOutput")
    if isinstance(hook_specific, dict):
        hook_specific = dict(hook_specific)
    else:
        hook_specific = {}
    hook_specific["hookEventName"] = "PreToolUse"
    hook_specific["permissionDecision"] = "deny"
    hook_specific["permissionDecisionReason"] = reason
    print(json.dumps({
        "hookSpecificOutput": hook_specific,
    }, ensure_ascii=False))
elif decision == "warn":
    output = native_pretool_output() if native_output else {}
    if reason:
        output["systemMessage"] = reason
    if output:
        print(json.dumps(output, ensure_ascii=False))
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
native_output = isinstance(data.get("hookSpecificOutput"), dict) or "systemMessage" in data

def native_posttool_output() -> dict:
    output = {}
    if "systemMessage" in data:
        output["systemMessage"] = data["systemMessage"]
    hook_specific = data.get("hookSpecificOutput")
    if isinstance(hook_specific, dict):
        output["hookSpecificOutput"] = dict(hook_specific)
    return output

if native_output and decision == "pass":
    passthrough = native_posttool_output()
    if passthrough:
        print(json.dumps(passthrough, ensure_ascii=False))
    sys.exit(0)

if decision in ("block", "escalate"):
    hook_specific = data.get("hookSpecificOutput")
    if isinstance(hook_specific, dict):
        hook_specific = dict(hook_specific)
    else:
        hook_specific = {}
    hook_specific["hookEventName"] = "PostToolUse"
    hook_specific.setdefault("additionalContext", reason)
    print(json.dumps({
        "decision": "block",
        "reason": reason,
        "hookSpecificOutput": hook_specific,
    }, ensure_ascii=False))
elif decision == "warn":
    output = native_posttool_output() if native_output else {}
    if reason:
        output["systemMessage"] = reason
    if output:
        print(json.dumps(output, ensure_ascii=False))
PY
}

codex_adapt_permission_request() {
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
            "hookEventName": "PermissionRequest",
            "decision": {
                "behavior": "deny",
                "message": "VIBEGUARD hook failed: wrapped hook produced invalid JSON.",
            },
        }
    }, ensure_ascii=False))
    sys.exit(3)

decision = data.get("decision", "pass")
reason = data.get("reason", "")
updated = data.get("updatedInput")
native_output = isinstance(data.get("hookSpecificOutput"), dict) or "systemMessage" in data

if native_output and decision == "pass" and updated is None:
    output = {}
    if "systemMessage" in data:
        output["systemMessage"] = data["systemMessage"]
    hook_specific = data.get("hookSpecificOutput")
    if isinstance(hook_specific, dict):
        output["hookSpecificOutput"] = dict(hook_specific)
    if output:
        print(json.dumps(output, ensure_ascii=False))
    sys.exit(0)

if decision == "block":
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": {
                "behavior": "deny",
                "message": reason,
            },
        }
    }, ensure_ascii=False))
elif decision == "warn":
    print(json.dumps({"systemMessage": reason}, ensure_ascii=False))
elif decision == "allow" and isinstance(updated, dict):
    command = updated.get("command")
    if isinstance(command, str) and command:
        print(json.dumps({
            "systemMessage": (
                "VIBEGUARD note: Codex CLI PermissionRequest hooks cannot auto-apply command rewrites. "
                "Suggested command: " + command
            )
        }, ensure_ascii=False))
PY
}

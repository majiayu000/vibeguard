#!/usr/bin/env bash
# Codex wrapper diagnostics and tiny JSON helpers.

codex_runtime_path() {
  local helper_dir wrapper_dir candidate
  helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  wrapper_dir="${WRAPPER_DIR:-$(cd "${helper_dir}/.." && pwd)}"
  for candidate in \
    "${VIBEGUARD_RUNTIME:-}" \
    "${wrapper_dir}/../vibeguard-runtime/target/debug/vibeguard-runtime" \
    "${wrapper_dir}/../vibeguard-runtime/target/release/vibeguard-runtime" \
    "${HOME}/.vibeguard/installed/bin/vibeguard-runtime" \
    "${wrapper_dir}/vibeguard-runtime"; do
    if [[ -n "${candidate}" && -f "${candidate}" && -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

codex_runtime_stdin() {
  local command_name="$1" input="$2" runtime_path
  if ! runtime_path="$(codex_runtime_path)"; then
    return 127
  fi
  printf '%s' "${input}" | "${runtime_path}" "${command_name}"
}

codex_raw_event_name() {
  local input="$1"
  if codex_runtime_stdin "codex-event-name" "${input}" 2>/dev/null; then
    return 0
  fi
  printf '%s' "${input}" | python3 -c '
import json
import sys

try:
    print(json.loads(sys.stdin.read()).get("hook_event_name", ""))
except Exception:
    print("")
'
}

codex_pretool_deny_raw() {
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

codex_permission_deny_raw() {
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

codex_visible_failure_raw() {
  local event_name="$1" reason="$2"
  CODEX_EVENT_NAME="${event_name}" CODEX_REASON="${reason}" python3 - <<'PY'
import json
import os

event = os.environ.get("CODEX_EVENT_NAME", "")
reason = os.environ.get("CODEX_REASON", "")
if event == "PreToolUse":
    payload = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }
elif event == "PermissionRequest":
    payload = {
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": {"behavior": "deny", "message": reason},
        }
    }
elif event == "PostToolUse":
    payload = {
        "decision": "block",
        "reason": reason,
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": reason,
        },
    }
elif event == "Stop":
    payload = {"stopReason": reason}
else:
    payload = {"systemMessage": reason}
print(json.dumps(payload, ensure_ascii=False))
PY
}

codex_set_caller_identity() {
  local event_name="$1"
  export VIBEGUARD_WRAPPER="${VIBEGUARD_WRAPPER:-run-hook-codex.sh}"
  export VIBEGUARD_SOURCE_CONFIG="${VIBEGUARD_SOURCE_CONFIG:-${HOME}/.codex/hooks.json}"
  export VIBEGUARD_HOOK_PROTOCOL_VERSION="${VIBEGUARD_HOOK_PROTOCOL_VERSION:-codex-hooks-v1}"
  if [[ -n "${event_name}" ]]; then
    export VIBEGUARD_AGENT_TYPE="codex"
    export VIBEGUARD_CLI="codex"
    export VIBEGUARD_CLIENT="codex"
    export VIBEGUARD_CLIENT_VARIANT="codex-cli-hooks"
    export VIBEGUARD_CALLER_EVIDENCE="codex-hook-payload"
  else
    export VIBEGUARD_CLIENT="${VIBEGUARD_CLIENT:-unknown}"
    export VIBEGUARD_CLIENT_VARIANT="${VIBEGUARD_CLIENT_VARIANT:-unknown}"
    export VIBEGUARD_CALLER_EVIDENCE="${VIBEGUARD_CALLER_EVIDENCE:-missing-codex-hook-payload}"
  fi
}

codex_diag() {
  local hook_name="$1" event_name="$2" reason="$3" detail="${4:-}"
  local detail_excerpt="${detail:0:300}"
  local diag_file="${VIBEGUARD_CODEX_DIAG_FILE:-${HOME}/.vibeguard/codex-wrapper.jsonl}"
  mkdir -p "$(dirname "${diag_file}")" 2>/dev/null || return 0
  VIBEGUARD_DIAG_FILE="${diag_file}" \
  VIBEGUARD_DIAG_HOOK="${hook_name}" \
  VIBEGUARD_DIAG_EVENT="${event_name}" \
  VIBEGUARD_DIAG_REASON="${reason}" \
  VIBEGUARD_DIAG_DETAIL="${detail_excerpt}" \
  VIBEGUARD_DIAG_CWD="${PWD}" \
    python3 - <<'PY' 2>/dev/null || true
import datetime
import json
import os
from pathlib import Path

path = Path(os.environ["VIBEGUARD_DIAG_FILE"])
ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
entry = {
    "ts": ts,
    "cli": "codex",
    "hook": os.environ.get("VIBEGUARD_DIAG_HOOK", ""),
    "event": os.environ.get("VIBEGUARD_DIAG_EVENT", ""),
    "reason": os.environ.get("VIBEGUARD_DIAG_REASON", ""),
    "detail": os.environ.get("VIBEGUARD_DIAG_DETAIL", "")[:300],
    "cwd": os.environ.get("VIBEGUARD_DIAG_CWD", ""),
}
with path.open("a", encoding="utf-8") as f:
    f.write(json.dumps(entry, ensure_ascii=False) + "\n")
try:
    path.chmod(0o600)
except OSError:
    pass
PY
}

codex_hook_timeout_ms() {
  local hook_name="$1"
  case "${hook_name}" in
    *post-build-check*) printf '%s\n' "30000" ;;
    *pre-*|*post-edit*|*post-write*) printf '%s\n' "10000" ;;
    *) printf '%s\n' "" ;;
  esac
}

codex_hook_status_detail() {
  local input="$1"
  if codex_runtime_stdin "codex-status-detail" "${input}" 2>/dev/null; then
    return 0
  fi
  printf '%s' "${input}" | python3 -c '
import json
import sys

try:
    payload = json.loads(sys.stdin.read())
except Exception:
    print("")
    raise SystemExit

tool_input = payload.get("tool_input")
if not isinstance(tool_input, dict):
    print("")
    raise SystemExit

for key in ("file_path", "command"):
    value = tool_input.get(key)
    if isinstance(value, str) and value:
        print(value[:300])
        raise SystemExit
print("")
'
}

codex_hook_status_matcher() {
  local input="$1"
  if codex_runtime_stdin "codex-status-matcher" "${input}" 2>/dev/null; then
    return 0
  fi
  printf '%s' "${input}" | python3 -c '
import json
import sys

try:
    payload = json.loads(sys.stdin.read())
except Exception:
    print("")
    raise SystemExit

tool_name = payload.get("tool_name")
print(tool_name if isinstance(tool_name, str) else "")
'
}

codex_hook_status() {
  local hook_name="$1" event_name="$2" matcher="$3" status="$4" reason="${5:-}" detail="${6:-}"
  local timeout_ms="${7:-}"
  local detail_excerpt="${detail:0:300}"
  local diag_file="${VIBEGUARD_CODEX_DIAG_FILE:-${HOME}/.vibeguard/codex-wrapper.jsonl}"
  mkdir -p "$(dirname "${diag_file}")" 2>/dev/null || return 0
  VIBEGUARD_DIAG_FILE="${diag_file}" \
  VIBEGUARD_DIAG_HOOK="${hook_name}" \
  VIBEGUARD_DIAG_EVENT="${event_name}" \
  VIBEGUARD_DIAG_MATCHER="${matcher}" \
  VIBEGUARD_DIAG_STATUS="${status}" \
  VIBEGUARD_DIAG_REASON="${reason}" \
  VIBEGUARD_DIAG_DETAIL="${detail_excerpt}" \
  VIBEGUARD_DIAG_TIMEOUT_MS="${timeout_ms}" \
    python3 - <<'PY' 2>/dev/null || true
import datetime
import json
import os
from pathlib import Path

def clean_hook(name: str) -> str:
    if name.startswith("vibeguard-"):
        name = name[len("vibeguard-"):]
    if name.endswith(".sh"):
        name = name[:-3]
    return name

path = Path(os.environ["VIBEGUARD_DIAG_FILE"])
entry = {
    "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "cli": "codex",
    "hook": clean_hook(os.environ.get("VIBEGUARD_DIAG_HOOK", "")),
    "event": os.environ.get("VIBEGUARD_DIAG_EVENT", ""),
    "matcher": os.environ.get("VIBEGUARD_DIAG_MATCHER", ""),
    "status": os.environ.get("VIBEGUARD_DIAG_STATUS", ""),
    "reason": os.environ.get("VIBEGUARD_DIAG_REASON", ""),
    "detail": os.environ.get("VIBEGUARD_DIAG_DETAIL", "")[:300],
}
timeout_ms = os.environ.get("VIBEGUARD_DIAG_TIMEOUT_MS", "")
if timeout_ms.isdigit():
    entry["timeout_ms"] = int(timeout_ms)
with path.open("a", encoding="utf-8") as f:
    f.write(json.dumps(entry, ensure_ascii=False) + "\n")
try:
    path.chmod(0o600)
except OSError:
    pass
PY
}

codex_hook_status_from_output() {
  local hook_name="$1" event_name="$2" matcher="$3" hook_output="$4" detail="${5:-}" timeout_ms="${6:-}"
  local parsed hook_status hook_reason
  if ! parsed=$(codex_runtime_stdin "codex-status-from-output" "${hook_output}" 2>/dev/null); then
    parsed=$(printf '%s' "${hook_output}" | python3 -c '
import json
import sys

try:
    data = json.loads(sys.stdin.read())
except Exception:
    print("hook_error\tinvalid-json")
    raise SystemExit

decision = data.get("decision", "pass")
reason = data.get("reason", "")
hook_specific = data.get("hookSpecificOutput")
if not isinstance(reason, str):
    reason = ""
if not isinstance(decision, str):
    decision = "pass"

status = "pass"
if decision in {"warn", "block", "gate", "escalate", "correction"}:
    status = decision
elif decision == "skip":
    status = "skipped"
elif isinstance(hook_specific, dict):
    if hook_specific.get("permissionDecision") == "deny":
        status = "block"
    nested_decision = hook_specific.get("decision")
    if isinstance(nested_decision, dict) and nested_decision.get("behavior") == "deny":
        status = "block"

reason = reason.replace("\t", " ").replace("\n", " ")[:300]
print(f"{status}\t{reason}")
' 2>/dev/null || true
    )
  fi
  hook_status="${parsed%%$'\t'*}"
  hook_reason="${parsed#*$'\t'}"
  if [[ "${hook_status}" == "${parsed}" ]]; then
    hook_reason=""
  fi
  [[ -n "${hook_status}" ]] || hook_status="hook_error"
  codex_hook_status "${hook_name}" "${event_name}" "${matcher}" "${hook_status}" "${hook_reason}" "${detail}" "${timeout_ms}"
}

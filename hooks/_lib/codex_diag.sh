#!/usr/bin/env bash
# Codex wrapper diagnostics and tiny JSON helpers.

codex_raw_event_name() {
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

codex_diag() {
  local hook_name="$1" event_name="$2" reason="$3" detail="${4:-}"
  local diag_file="${VIBEGUARD_CODEX_DIAG_FILE:-${HOME}/.vibeguard/codex-wrapper.jsonl}"
  mkdir -p "$(dirname "${diag_file}")" 2>/dev/null || return 0
  VIBEGUARD_DIAG_FILE="${diag_file}" \
  VIBEGUARD_DIAG_HOOK="${hook_name}" \
  VIBEGUARD_DIAG_EVENT="${event_name}" \
  VIBEGUARD_DIAG_REASON="${reason}" \
  VIBEGUARD_DIAG_DETAIL="${detail}" \
  VIBEGUARD_DIAG_CWD="${PWD}" \
    python3 - <<'PY' 2>/dev/null || true
import datetime
import json
import os
from pathlib import Path

path = Path(os.environ["VIBEGUARD_DIAG_FILE"])
entry = {
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
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

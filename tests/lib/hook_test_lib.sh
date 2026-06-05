#!/usr/bin/env bash

TEST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${VIBEGUARD_REPO_DIR:-$(cd "${TEST_LIB_DIR}/../.." && pwd)}"
cd "$REPO_DIR"

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header(){ printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

assert_contains() {
  local output="$1" expected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$output" | grep -qF "$expected"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected to contain: $expected)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local output="$1" unexpected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if ! echo "$output" | grep -qF "$unexpected"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (unexpectedly contains: $unexpected)"
    FAIL=$((FAIL + 1))
  fi
}

assert_occurrences() {
  local output="$1" needle="$2" expected_count="$3" desc="$4"
  local actual_count
  TOTAL=$((TOTAL + 1))
  actual_count=$(python3 -c '
import sys

haystack = sys.argv[1]
needle = sys.argv[2]
print(haystack.count(needle))
' "$output" "$needle")
  if [[ "$actual_count" == "$expected_count" ]]; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected $expected_count occurrences of: $needle, got $actual_count)"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit_zero() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (exit code: $?)"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit_nonzero() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    red "$desc (unexpected success)"
    FAIL=$((FAIL + 1))
  else
    green "$desc"
    PASS=$((PASS + 1))
  fi
}

hook_test_init() {
  export VIBEGUARD_LOG_DIR="${VIBEGUARD_LOG_DIR:-$(mktemp -d)}"
  trap 'rm -rf "$VIBEGUARD_LOG_DIR"' EXIT
}

hook_test_install_runtime_stub() {
  local home_dir="$1"
  local runtime="${home_dir}/.vibeguard/installed/bin/vibeguard-runtime"
  mkdir -p "$(dirname "$runtime")"
  cat > "$runtime" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

command="${1:-}"
shift || true

case "$command" in
  append-jsonl)
    file="${1:?append-jsonl requires a file path}"
    line="$(cat)"
    mkdir -p "$(dirname "$file")"
    printf '%s\n' "$line" >> "$file"
    ;;
  json-field)
    strict=0
    if [[ "${1:-}" == "--strict" ]]; then
      strict=1
      shift
    fi
    field="${1:-}"
    input="$(cat)"
    RUNTIME_INPUT="$input" python3 - "$field" "$strict" <<'PY'
import json
import os
import sys

field = sys.argv[1]
strict = sys.argv[2] == "1"
try:
    value = json.loads(os.environ.get("RUNTIME_INPUT", ""))
    for part in field.split("."):
        value = value[part]
except Exception:
    if strict:
        raise SystemExit(1)
    print("")
    raise SystemExit(0)
if value is None:
    if strict:
        raise SystemExit(1)
    print("")
elif isinstance(value, str):
    print(value)
else:
    print(json.dumps(value))
PY
    ;;
  codex-event-name)
    python3 - <<'PY'
import json
import sys

try:
    print(json.loads(sys.stdin.read()).get("hook_event_name", ""))
except Exception:
    print("")
PY
    ;;
  codex-status-detail|codex-status-matcher|codex-status-from-output)
    cat >/dev/null
    ;;
  codex-normalize-apply-patch)
    shift || true
    cat
    ;;
  codex-pretool-deny)
    reason="$(cat)"
    REASON="$reason" python3 - <<'PY'
import json
import os

print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": os.environ.get("REASON", "")}}, ensure_ascii=False))
PY
    ;;
  codex-permission-deny)
    reason="$(cat)"
    REASON="$reason" python3 - <<'PY'
import json
import os

print(json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "deny", "message": os.environ.get("REASON", "")}}}, ensure_ascii=False))
PY
    ;;
  codex-adapt-pretool)
    python3 - <<'PY'
import json
import sys

try:
    data = json.loads(sys.stdin.read())
except Exception:
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "VIBEGUARD hook failed: wrapped hook produced invalid JSON."}}, ensure_ascii=False))
    raise SystemExit(3)

decision = data.get("decision", "pass")
reason = data.get("reason", "")
hook_specific = data.get("hookSpecificOutput")
native = isinstance(hook_specific, dict) or "systemMessage" in data
if native and decision == "pass" and data.get("updatedInput") is None:
    out = {}
    if "systemMessage" in data:
        out["systemMessage"] = data["systemMessage"]
    if isinstance(hook_specific, dict):
        out["hookSpecificOutput"] = dict(hook_specific)
    if out:
        print(json.dumps(out, ensure_ascii=False))
elif decision == "block":
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason}}, ensure_ascii=False))
elif decision == "warn" and reason:
    print(json.dumps({"systemMessage": reason}, ensure_ascii=False))
PY
    ;;
  codex-adapt-permission-request)
    python3 - <<'PY'
import json
import sys

try:
    data = json.loads(sys.stdin.read())
except Exception:
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "deny", "message": "VIBEGUARD hook failed: wrapped hook produced invalid JSON."}}}, ensure_ascii=False))
    raise SystemExit(3)

decision = data.get("decision", "pass")
reason = data.get("reason", "")
if decision == "block":
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "deny", "message": reason}}}, ensure_ascii=False))
elif decision == "warn" and reason:
    print(json.dumps({"systemMessage": reason}, ensure_ascii=False))
PY
    ;;
  codex-adapt-posttool)
    python3 - <<'PY'
import json
import sys

try:
    data = json.loads(sys.stdin.read())
except Exception:
    raise SystemExit(3)

decision = data.get("decision", "pass")
reason = data.get("reason", "")
if decision in {"block", "escalate"}:
    print(json.dumps({"decision": "block", "reason": reason, "hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": reason}}, ensure_ascii=False))
elif decision == "warn" and reason:
    print(json.dumps({"systemMessage": reason}, ensure_ascii=False))
PY
    ;;
  pkg-rewrite)
    cat >/dev/null
    ;;
  runtime-policy-check)
    hook_name="${1:?runtime-policy-check requires hook name}"
    python3 - "$hook_name" <<'PY'
import json
import os
import subprocess
import sys
from pathlib import Path

hook_name = sys.argv[1]
user_config = os.environ.get("VIBEGUARD_USER_CONFIG_FILE", "")
if user_config and Path(user_config).is_file():
    try:
        json.loads(Path(user_config).read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"VibeGuard runtime config invalid JSON: {user_config}: {exc}", file=sys.stderr)
        raise SystemExit(30)

def project_config_path() -> Path | None:
    configured = os.environ.get("VIBEGUARD_PROJECT_CONFIG", "")
    if configured and Path(configured).is_file():
        return Path(configured)
    try:
        git_root = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        ).stdout.strip()
    except OSError:
        git_root = ""
    if git_root and (Path(git_root) / ".vibeguard.json").is_file():
        return Path(git_root) / ".vibeguard.json"
    if Path(".vibeguard.json").is_file():
        return Path(".vibeguard.json")
    return None

def canonical(name: str) -> str:
    file_name = Path(name).name
    if file_name.endswith(".sh"):
        file_name = file_name[:-3]
    if file_name.startswith("vibeguard-"):
        file_name = file_name[len("vibeguard-"):]
    return file_name.replace("_", "-")

def profile_allows(profile: str, hook: str) -> bool:
    if hook == "analysis-paralysis-guard":
        return profile in {"core", "full", "strict"}
    if hook == "count-active-constraints":
        return profile == "strict"
    if hook in {"post-build-check", "stop-guard", "learn-evaluator"}:
        return profile in {"full", "strict"}
    return True

path = project_config_path()
if path is None:
    raise SystemExit(0)
try:
    config = json.loads(path.read_text(encoding="utf-8"))
except json.JSONDecodeError as exc:
    print(f"VibeGuard project config invalid JSON: {path}: {exc}", file=sys.stderr)
    raise SystemExit(30)
if not isinstance(config, dict):
    print(f"VibeGuard project config invalid: {path} must be a JSON object", file=sys.stderr)
    raise SystemExit(20)

allowed_hooks = {
    "analysis-paralysis-guard",
    "count-active-constraints",
    "learn-evaluator",
    "post-build-check",
    "post-edit-guard",
    "post-write-guard",
    "pre-bash-guard",
    "pre-commit-guard",
    "pre-edit-guard",
    "pre-write-guard",
    "stop-guard",
}
disabled = config.get("disabled_hooks", [])
if not isinstance(disabled, list) or any(not isinstance(item, str) for item in disabled):
    print(f"VibeGuard project config invalid: {path} field disabled_hooks must contain only strings", file=sys.stderr)
    raise SystemExit(20)
for item in disabled:
    if item not in allowed_hooks:
        print(f"VibeGuard project config invalid: {path} disabled_hooks contains unsupported hook {item}", file=sys.stderr)
        raise SystemExit(20)

hook = canonical(hook_name)
enforcement = config.get("enforcement", "block")
if enforcement == "off":
    print("VibeGuard policy skip: enforcement=off")
    raise SystemExit(10)
if hook in disabled:
    print(f"VibeGuard policy skip: disabled_hooks contains {hook}")
    raise SystemExit(10)
profile = config.get("profile", "core")
if isinstance(profile, str) and not profile_allows(profile, hook):
    print(f"VibeGuard policy skip: profile={profile} excludes {hook}")
    raise SystemExit(10)
if enforcement == "warn":
    print("VibeGuard policy warn: enforcement=warn")
raise SystemExit(0)
PY
    ;;
  runtime-policy-downgrade-output)
    python3 - <<'PY'
import json
import sys

raw = sys.stdin.read()
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    sys.stdout.write(raw)
    if raw and not raw.endswith("\n"):
        sys.stdout.write("\n")
    raise SystemExit(0)

if not isinstance(data, dict):
    print(json.dumps(data, ensure_ascii=False))
    raise SystemExit(0)

reason = data.get("reason")
changed = False
if data.get("decision") in {"block", "gate", "escalate"}:
    data["decision"] = "warn"
    changed = True
if isinstance(reason, str) and reason and changed:
    data["reason"] = f"VIBEGUARD warn-mode advisory: {reason}"

hook_specific = data.get("hookSpecificOutput")
if isinstance(hook_specific, dict):
    if hook_specific.get("permissionDecision") == "deny":
        message = hook_specific.pop("permissionDecisionReason", None)
        hook_specific.pop("permissionDecision", None)
        if isinstance(message, str) and message and "systemMessage" not in data:
            data["systemMessage"] = f"VIBEGUARD warn-mode advisory: {message}"
    decision = hook_specific.get("decision")
    if isinstance(decision, dict) and decision.get("behavior") == "deny":
        message = decision.get("message")
        hook_specific.pop("decision", None)
        if isinstance(message, str) and message and "systemMessage" not in data:
            data["systemMessage"] = f"VIBEGUARD warn-mode advisory: {message}"

print(json.dumps(data, ensure_ascii=False))
PY
    ;;
  runtime-policy-codex-error)
    event_name="${1:-}"
    reason="$(cat)"
    EVENT_NAME="$event_name" REASON="$reason" python3 - <<'PY'
import json
import os

event = os.environ.get("EVENT_NAME", "")
reason = os.environ.get("REASON", "")
if event == "PreToolUse":
    payload = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason}}
elif event == "PermissionRequest":
    payload = {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "deny", "message": reason}}}
elif event == "PostToolUse":
    payload = {"decision": "block", "reason": reason, "hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": reason}}
elif event == "Stop":
    payload = {"stopReason": reason}
else:
    payload = {"systemMessage": reason}
print(json.dumps(payload, ensure_ascii=False))
PY
    ;;
  runtime-policy-diag)
    diag_file="${1:?diag path}"
    hook_name="${2:-}"
    event_name="${3:-}"
    kind="${4:-}"
    wrapper="${5:-}"
    reason="$(cat)"
    mkdir -p "$(dirname "$diag_file")"
    DIAG_FILE="$diag_file" HOOK_NAME="$hook_name" EVENT_NAME="$event_name" KIND="$kind" WRAPPER="$wrapper" REASON="$reason" python3 - <<'PY'
import datetime
import json
import os
from pathlib import Path

entry = {
    "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "wrapper": os.environ.get("WRAPPER", ""),
    "hook": os.environ.get("HOOK_NAME", ""),
    "event": os.environ.get("EVENT_NAME", ""),
    "kind": os.environ.get("KIND", ""),
    "reason": os.environ.get("REASON", ""),
}
path = Path(os.environ["DIAG_FILE"])
with path.open("a", encoding="utf-8") as fh:
    fh.write(json.dumps(entry, ensure_ascii=False) + "\n")
PY
    ;;
  runtime-config-get-int)
    env_name="${1:?env name}"
    json_path="${2:?json path}"
    default_val="${3:?default}"
    config_file="${4:-}"
    val="${!env_name:-}"
    if [[ -n "$val" && "$val" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$val"
    else
      python3 - "$config_file" "$json_path" "$default_val" <<'PY'
import json
import sys
from pathlib import Path

path, json_path, default = sys.argv[1:4]
try:
    node = json.loads(Path(path).read_text(encoding="utf-8"))
    for key in json_path.split("."):
        node = node[key]
    if isinstance(node, bool) or not isinstance(node, int) or node < 0:
        raise ValueError
    print(node)
except Exception:
    print(default)
PY
    fi
    ;;
  runtime-config-get-str)
    env_name="${1:?env name}"
    json_path="${2:?json path}"
    default_val="${3:?default}"
    config_file="${4:-}"
    val="${!env_name:-}"
    if [[ -n "$val" ]]; then
      printf '%s\n' "$val"
    else
      python3 - "$config_file" "$json_path" "$default_val" <<'PY'
import json
import sys
from pathlib import Path

path, json_path, default = sys.argv[1:4]
try:
    node = json.loads(Path(path).read_text(encoding="utf-8"))
    for key in json_path.split("."):
        node = node[key]
    if not isinstance(node, str) or not node:
        raise ValueError
    print(node)
except Exception:
    print(default)
PY
    fi
    ;;
  pre-write-check)
    cat >/dev/null
    printf 'PASS\n'
    ;;
  *)
    cat >/dev/null || true
    ;;
esac
STUB
  chmod +x "$runtime"
}

hook_test_finish() {
  echo
  echo "=============================="
  printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
  echo "=============================="

  if [[ $FAIL -gt 0 ]]; then
    exit 1
  fi
}

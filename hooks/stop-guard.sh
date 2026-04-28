#!/usr/bin/env bash
# VibeGuard Stop Hook — Verify access control before completion
#
# Check if there are any uncommitted source code changes at the end of the AI session.
# There are uncommitted changes → exit 0 (log only; exit 2 will trigger an infinite loop in the Stop context)
# No changes or non-git repository → exit 0 (pass silently)

set -euo pipefail

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/circuit-breaker.sh"
vg_start_timer

# CI guard: skip interactive hooks in CI environments
vg_is_ci && exit 0

# Read stdin once (Stop hook receives JSON input)
INPUT=$(cat 2>/dev/null || true)

# stop_hook_active: platform sets this when a Stop hook triggered another Stop hook.
# Checking it breaks the feedback → Stop hook → feedback → Stop hook infinite loop.
vg_stop_hook_active "$INPUT" && exit 0

# Not in git repository → skip
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  exit 0
fi

# Check if there are any uncommitted or untracked source code changes.
changed_source_files=""
while IFS= read -r file; do
  if [[ -n "$file" ]] && vg_is_source_file "$file"; then
    changed_source_files="${changed_source_files}${file}"$'\n'
  fi
done < <(
  {
    git diff --name-only HEAD 2>/dev/null || true
    git diff --name-only --cached 2>/dev/null || true
    git ls-files --others --exclude-standard 2>/dev/null || true
  } | sed '/^$/d'
)

# Remove duplicates
if [[ -n "$changed_source_files" ]]; then
  changed_source_files=$(echo "$changed_source_files" | sort -u)
fi

scope_meta_json=$(vg_omx_scope_meta 2>/dev/null || echo '{"error":"omx scope resolution failed"}')
latest_verification_json=$(vg_omx_latest_verification 2>/dev/null || echo '{"error":"verification lookup failed"}')

decision_json=$(
  VG_SCOPE_META="$scope_meta_json" \
  VG_LATEST_VERIFICATION="$latest_verification_json" \
  VG_CHANGED_SOURCE_FILES="$changed_source_files" \
  VG_EXPLICIT_STATUS="${VIBEGUARD_LIFECYCLE_STATUS:-}" \
  VG_NEXT_REQUIRED_ACTION="${VIBEGUARD_NEXT_REQUIRED_ACTION:-}" \
  python3 - <<'PY'
import json
import os

scope_meta = json.loads(os.environ.get("VG_SCOPE_META", "{}"))
latest_raw = json.loads(os.environ.get("VG_LATEST_VERIFICATION", "{}"))
latest = latest_raw.get("verification") if isinstance(latest_raw, dict) else None
explicit_status = os.environ.get("VG_EXPLICIT_STATUS", "")
changed_files = [line for line in os.environ.get("VG_CHANGED_SOURCE_FILES", "").splitlines() if line.strip()]
known_failures = []
verification_status = "missing"
verification_commands = []
verification_entry_id = None
latest_status = None
if isinstance(latest, dict):
    latest_status = latest.get("status")
    verification_status = latest_status or "unknown"
    verification_commands = latest.get("commands") or []
    verification_entry_id = latest.get("entry_id")
    known_failures.extend(latest.get("known_failures") or [])

pointer_error = scope_meta.get("pointer_error")
if isinstance(pointer_error, str) and pointer_error:
    known_failures.append(f"current-plan-pointer-error: {pointer_error}")

mode = scope_meta.get("mode") or os.environ.get("VIBEGUARD_MODE") or os.environ.get("VIBEGUARD_CLI") or "unknown"
current_step = scope_meta.get("current_step")
scope = scope_meta.get("scope", "unknown")
response = None
log_decision = "pass"
log_reason = ""
log_detail = ""

if explicit_status in {"failed", "cancelled"}:
    status = explicit_status
    verification_status = verification_status if verification_status != "missing" else "unknown"
    next_required_action = os.environ.get("VG_NEXT_REQUIRED_ACTION") or (
        "Investigate the failure before resuming work." if explicit_status == "failed" else "Resume only after selecting a new active scope."
    )
    response = f"VIBEGUARD lifecycle marked {explicit_status} for scope {scope}."
    log_decision = "warn"
    log_reason = f"lifecycle marked {explicit_status}"
elif changed_files:
    status = "incomplete"
    verification_status = "stale" if latest_status == "pass" else verification_status
    next_required_action = "Commit or revert changed source files, then rerun verification for the active scope."
    preview = " ".join(changed_files[:5])
    count = len(changed_files)
    known_failures.append(f"changed_source_files:{count}")
    response = f"VIBEGUARD lifecycle incomplete: {count} source file(s) still changed for scope {scope}."
    log_decision = "gate"
    log_reason = f"unverified source changes: {count} files"
    log_detail = preview
elif latest_status != "pass":
    status = "incomplete"
    verification_status = latest_status or "missing"
    next_required_action = "Run verification commands and append a passing verification entry for the active scope."
    if verification_status == "missing":
        response = f"VIBEGUARD lifecycle incomplete: no passing verification artifact exists for scope {scope}."
        log_reason = "missing verification artifact"
    else:
        response = f"VIBEGUARD lifecycle incomplete: latest verification status for scope {scope} is {verification_status}."
        log_reason = f"verification status {verification_status}"
    log_decision = "gate"
else:
    status = "completed"
    verification_status = "pass"
    next_required_action = None
    log_decision = "complete"
    log_reason = "verification artifact confirmed"

completion = {
    "mode": mode,
    "status": status,
    "current_step": current_step,
    "verification_status": verification_status,
    "verification_entry_id": verification_entry_id,
    "verification_commands": verification_commands,
    "known_failures": known_failures,
    "next_required_action": next_required_action,
}

print(json.dumps({
    "completion": completion,
    "response": response,
    "log_decision": log_decision,
    "log_reason": log_reason,
    "log_detail": log_detail,
}, ensure_ascii=False))
PY
)

completion_payload=$(printf '%s' "$decision_json" | python3 -c 'import json,sys; print(json.dumps(json.loads(sys.stdin.read())["completion"], ensure_ascii=False))' 2>/dev/null || echo "{}")
write_result=$(vg_omx_write_completion "$completion_payload" 2>/dev/null || echo '{"error":"completion write failed"}')
write_error=$(printf '%s' "$write_result" | python3 -c 'import json,sys; data=json.loads(sys.stdin.read()); print(data.get("error",""))' 2>/dev/null || echo "")

if [[ -n "$write_error" ]]; then
  fallback_payload=$(
    VG_WRITE_ERROR="$write_error" \
    VG_COMPLETION_PAYLOAD="$completion_payload" \
    python3 - <<'PY'
import json
import os

payload = json.loads(os.environ["VG_COMPLETION_PAYLOAD"])
known_failures = list(payload.get("known_failures") or [])
known_failures.append(f"completion-write-error: {os.environ['VG_WRITE_ERROR']}")
payload.update(
    {
        "status": "incomplete",
        "verification_status": "unknown",
        "known_failures": known_failures,
        "next_required_action": "Repair malformed OMX state and rerun verification before claiming completion.",
    }
)
print(json.dumps(payload, ensure_ascii=False))
PY
  )
  write_result=$(vg_omx_write_completion "$fallback_payload" 2>/dev/null || echo '{"error":"fallback completion write failed"}')
  decision_json=$(
    VG_DECISION_JSON="$decision_json" \
    VG_WRITE_ERROR="$write_error" \
    python3 - <<'PY'
import json
import os

decision = json.loads(os.environ["VG_DECISION_JSON"])
decision["response"] = "VIBEGUARD lifecycle incomplete: prior OMX state was malformed and was reset to an incomplete state."
decision["log_decision"] = "gate"
decision["log_reason"] = f"malformed lifecycle state: {os.environ['VG_WRITE_ERROR']}"
print(json.dumps(decision, ensure_ascii=False))
PY
  )
fi

log_decision=$(printf '%s' "$decision_json" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("log_decision","pass"))' 2>/dev/null || echo "pass")
log_reason=$(printf '%s' "$decision_json" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("log_reason",""))' 2>/dev/null || echo "")
log_detail=$(printf '%s' "$decision_json" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("log_detail",""))' 2>/dev/null || echo "")
vg_log "stop-guard" "Stop" "$log_decision" "$log_reason" "$log_detail"

response_message=$(printf '%s' "$decision_json" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("response") or "")' 2>/dev/null || echo "")
if [[ -n "$response_message" ]]; then
  VG_STOP_REASON="$response_message" python3 - <<'PY'
import json
import os

print(json.dumps({"stopReason": os.environ["VG_STOP_REASON"]}, ensure_ascii=False))
PY
fi

exit 0

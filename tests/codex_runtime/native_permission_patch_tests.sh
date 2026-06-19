header "run-hook-codex passes native Codex hook output through"
TMP_HOME_NATIVE="${TMP_DIR}/home-native"
TMP_FAKE_REPO_NATIVE="${TMP_DIR}/fake-repo-native"
mkdir -p "${TMP_HOME_NATIVE}/.vibeguard" "${TMP_FAKE_REPO_NATIVE}/hooks"
printf '%s' "${TMP_FAKE_REPO_NATIVE}" > "${TMP_HOME_NATIVE}/.vibeguard/repo-path"

cat > "${TMP_FAKE_REPO_NATIVE}/hooks/vibeguard-pre-write-guard.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
python3 - <<'PY'
import json
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "additionalContext": "search before writing new source",
    }
}))
PY
HOOK
chmod +x "${TMP_FAKE_REPO_NATIVE}/hooks/vibeguard-pre-write-guard.sh"

native_pretool_out="$(
  printf '{"hook_event_name":"PreToolUse","tool_input":{"file_path":"src/new.ts"}}' \
    | HOME="${TMP_HOME_NATIVE}" bash "${REPO_DIR}/hooks/run-hook-codex.sh" vibeguard-pre-write-guard.sh
)"
assert_contains "${native_pretool_out}" '"hookEventName": "PreToolUse"' "run-hook-codex preserves native PreToolUse output"
assert_contains "${native_pretool_out}" 'search before writing new source' "run-hook-codex preserves native PreToolUse additionalContext"

cat > "${TMP_FAKE_REPO_NATIVE}/hooks/vibeguard-post-edit-guard.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
python3 - <<'PY'
import json
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": "quality warning reached Codex",
    }
}))
PY
HOOK
chmod +x "${TMP_FAKE_REPO_NATIVE}/hooks/vibeguard-post-edit-guard.sh"

native_posttool_out="$(
  printf '{"hook_event_name":"PostToolUse","tool_input":{"file_path":"src/main.ts"},"tool_response":{"output":"ok"}}' \
    | HOME="${TMP_HOME_NATIVE}" bash "${REPO_DIR}/hooks/run-hook-codex.sh" vibeguard-post-edit-guard.sh
)"
assert_contains "${native_posttool_out}" '"hookEventName": "PostToolUse"' "run-hook-codex preserves native PostToolUse output"
assert_contains "${native_posttool_out}" 'quality warning reached Codex' "run-hook-codex preserves native PostToolUse additionalContext"

cat > "${TMP_FAKE_REPO_NATIVE}/hooks/vibeguard-pre-bash-guard.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
python3 - <<'PY'
import json
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PermissionRequest",
        "decision": {
            "behavior": "deny",
            "message": "native permission deny reached Codex",
        },
    }
}))
PY
HOOK
chmod +x "${TMP_FAKE_REPO_NATIVE}/hooks/vibeguard-pre-bash-guard.sh"

native_permission_out="$(
  printf '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' \
    | HOME="${TMP_HOME_NATIVE}" bash "${REPO_DIR}/hooks/run-hook-codex.sh" vibeguard-pre-bash-guard.sh
)"
assert_contains "${native_permission_out}" '"hookEventName": "PermissionRequest"' "run-hook-codex preserves native PermissionRequest output"
assert_contains "${native_permission_out}" 'native permission deny reached Codex' "run-hook-codex preserves native PermissionRequest deny message"

cat > "${TMP_FAKE_REPO_POSTTOOL}/hooks/vibeguard-post-build-check.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
printf '{'
HOOK
chmod +x "${TMP_FAKE_REPO_POSTTOOL}/hooks/vibeguard-post-build-check.sh"
posttool_bad_diag="${TMP_DIR}/posttool-bad.jsonl"
bad_posttool_out="$({
  printf '{"hook_event_name":"PostToolUse","tool_input":{"command":"cargo check"}}' \
    | HOME="${TMP_HOME_POSTTOOL}" VIBEGUARD_CODEX_DIAG_FILE="${posttool_bad_diag}" bash "${REPO_DIR}/hooks/run-hook-codex.sh" vibeguard-post-build-check.sh
} 2>/dev/null)"
assert_contains "${bad_posttool_out}" '"decision": "block"' "invalid PostToolUse hook output emits visible feedback"
assert_contains "${bad_posttool_out}" 'could not be adapted' "invalid PostToolUse hook output explains adapter failure"
assert_codex_posttool_output_contract "${bad_posttool_out}" "invalid PostToolUse failure output matches Codex contract"
assert_contains "$(cat "${posttool_bad_diag}")" "posttool-adapter-failed" "invalid PostToolUse output writes diagnostic event"

header "run-hook-codex adapts PermissionRequest decisions"
TMP_HOME_PERMISSION="${TMP_DIR}/home-permission"
TMP_FAKE_REPO_PERMISSION="${TMP_DIR}/fake-repo-permission"
mkdir -p "${TMP_HOME_PERMISSION}/.vibeguard" "${TMP_FAKE_REPO_PERMISSION}/hooks"
printf '%s' "${TMP_FAKE_REPO_PERMISSION}" > "${TMP_HOME_PERMISSION}/.vibeguard/repo-path"

cat > "${TMP_FAKE_REPO_PERMISSION}/hooks/vibeguard-pre-bash-guard.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
python3 - <<'PY'
import json
print(json.dumps({"decision": "block", "reason": "permission denied by vibeguard"}))
PY
HOOK
chmod +x "${TMP_FAKE_REPO_PERMISSION}/hooks/vibeguard-pre-bash-guard.sh"

permission_out="$(
  printf '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' \
    | HOME="${TMP_HOME_PERMISSION}" bash "${REPO_DIR}/hooks/run-hook-codex.sh" vibeguard-pre-bash-guard.sh
)"
assert_contains "${permission_out}" '"hookEventName": "PermissionRequest"' "run-hook-codex emits PermissionRequest output"
assert_contains "${permission_out}" '"behavior": "deny"' "run-hook-codex maps block to PermissionRequest deny"
assert_contains "${permission_out}" 'permission denied by vibeguard' "run-hook-codex preserves PermissionRequest deny reason"

header "run-hook-codex normalizes apply_patch payloads for file hooks"
TMP_HOME_PATCH="${TMP_DIR}/home-patch"
TMP_FAKE_REPO_PATCH="${TMP_DIR}/fake-repo-patch"
mkdir -p "${TMP_HOME_PATCH}/.vibeguard" "${TMP_FAKE_REPO_PATCH}/hooks"
printf '%s' "${TMP_FAKE_REPO_PATCH}" > "${TMP_HOME_PATCH}/.vibeguard/repo-path"

cat > "${TMP_FAKE_REPO_PATCH}/hooks/vibeguard-pre-write-guard.sh" <<'HOOK'
#!/usr/bin/env bash
payload=$(cat)
PAYLOAD="$payload" python3 - <<'PY'
import json
import os
payload = json.loads(os.environ["PAYLOAD"])
tool_input = payload["tool_input"]
reason = f"normalized:{payload['tool_name']}:{tool_input.get('file_path')}:{tool_input.get('content')}"
print(json.dumps({"decision": "block", "reason": reason}))
PY
HOOK
chmod +x "${TMP_FAKE_REPO_PATCH}/hooks/vibeguard-pre-write-guard.sh"

patch_input="$(python3 - <<'PY'
import json
patch = """*** Begin Patch
*** Add File: src/new.rs
+fn main() {}
*** End Patch"""
print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":patch}}))
PY
)"
patch_out="$(
  printf '%s' "${patch_input}" \
    | HOME="${TMP_HOME_PATCH}" bash "${REPO_DIR}/hooks/run-hook-codex.sh" vibeguard-pre-write-guard.sh
)"
assert_contains "${patch_out}" '"permissionDecision": "deny"' "apply_patch Add File can be blocked through the Write alias"
assert_contains "${patch_out}" 'normalized:Write:src/new.rs:fn main() {}' "apply_patch Add File is normalized to a Write-shaped payload"

permission_patch_out="$(
  printf '%s' "${patch_input/PreToolUse/PermissionRequest}" \
    | HOME="${TMP_HOME_PATCH}" bash "${REPO_DIR}/hooks/run-hook-codex.sh" vibeguard-pre-write-guard.sh
)"
assert_contains "${permission_patch_out}" '"hookEventName": "PermissionRequest"' "apply_patch PermissionRequest keeps the PermissionRequest event"
assert_contains "${permission_patch_out}" '"behavior": "deny"' "apply_patch PermissionRequest can be denied through the Write alias"

cat > "${TMP_FAKE_REPO_PATCH}/hooks/vibeguard-pre-edit-guard.sh" <<'HOOK'
#!/usr/bin/env bash
payload=$(cat)
PAYLOAD="$payload" python3 - <<'PY'
import json
import os
payload = json.loads(os.environ["PAYLOAD"])
tool_input = payload["tool_input"]
reason = (
    f"normalized:{payload['tool_name']}:"
    f"{tool_input.get('file_path')}:"
    f"delta={tool_input.get('vibeguard_line_delta')}:"
    f"new={tool_input.get('new_string')}"
)
print(json.dumps({"decision": "block", "reason": reason}))
PY
HOOK
chmod +x "${TMP_FAKE_REPO_PATCH}/hooks/vibeguard-pre-edit-guard.sh"

patch_update_input="$(python3 - <<'PY'
import json
patch = """*** Begin Patch
*** Update File: src/existing.rs
@@
 fn main() {}
+println!("hi");
*** End Patch"""
print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":patch}}))
PY
)"
patch_update_out="$(
  printf '%s' "${patch_update_input}" \
    | HOME="${TMP_HOME_PATCH}" bash "${REPO_DIR}/hooks/run-hook-codex.sh" vibeguard-pre-edit-guard.sh
)"
assert_contains "${patch_update_out}" '"permissionDecision": "deny"' "apply_patch Update File can be blocked through the Edit alias"
assert_contains "${patch_update_out}" 'normalized:Edit:src/existing.rs:delta=1' "apply_patch Update File carries line delta to Edit hook"

printf '%s\n' '{"scoped_suppressions":[{"hook":"post-edit-guard","rule_id":"RS-03","path":"docs/examples/**","action":"suppress","reason":"Known documentation example false positive"}]}' > "${TMP_FAKE_REPO_PATCH}/.vibeguard.json"
cat > "${TMP_FAKE_REPO_PATCH}/hooks/vibeguard-post-edit-guard.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
python3 - <<'PY'
import json
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": "VIBEGUARD quality warning: [RS-03] unwrap in docs example",
    }
}))
PY
HOOK
chmod +x "${TMP_FAKE_REPO_PATCH}/hooks/vibeguard-post-edit-guard.sh"

scoped_patch_input="$(python3 - <<'PY'
import json
patch = """*** Begin Patch
*** Update File: docs/examples/basic.rs
@@
 fn main() {}
+let _ = value.unwrap();
*** End Patch"""
print(json.dumps({"hook_event_name":"PostToolUse","tool_name":"apply_patch","tool_input":{"command":patch}}))
PY
)"
scoped_patch_out="$(
  printf '%s' "${scoped_patch_input}" \
    | HOME="${TMP_HOME_PATCH}" VIBEGUARD_POLICY_CWD="${TMP_FAKE_REPO_PATCH}" bash "${REPO_DIR}/hooks/run-hook-codex.sh" vibeguard-post-edit-guard.sh
)"
TOTAL=$((TOTAL + 1))
if [[ -z "${scoped_patch_out}" ]]; then
  green "apply_patch scoped suppression hides normalized-payload advisory"
  PASS=$((PASS + 1))
else
  red "apply_patch scoped suppression hides normalized-payload advisory"
  FAIL=$((FAIL + 1))
fi
assert_not_contains "${scoped_patch_out}" 'additionalContext' "apply_patch scoped suppression clears native advisory context"

run_wrapper() {
  local app_repo="$1"
  local child_script="$2"
  local input="$3"
  printf '%b\n' "${input}" | "${VIBEGUARD_RUNTIME}" codex-app-server-wrapper \
    --repo-dir "${app_repo}" \
    --codex-command "bash '${child_script}'"
}

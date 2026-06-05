header "run-hook-codex surfaces unsupported command rewrite"
TMP_HOME="${TMP_DIR}/home"
TMP_FAKE_REPO="${TMP_DIR}/fake-repo"
mkdir -p "${TMP_HOME}/.vibeguard" "${TMP_FAKE_REPO}/hooks"
printf '%s' "${TMP_FAKE_REPO}" > "${TMP_HOME}/.vibeguard/repo-path"

cat > "${TMP_FAKE_REPO}/hooks/vibeguard-pre-bash-guard.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
printf '{"decision":"allow","updatedInput":{"command":"pnpm install"}}\n'
HOOK
chmod +x "${TMP_FAKE_REPO}/hooks/vibeguard-pre-bash-guard.sh"

rewrite_out="$(
  printf '{"hook_event_name":"PreToolUse","tool_input":{"command":"npm install"}}' \
    | HOME="${TMP_HOME}" bash "${REPO_DIR}/hooks/run-hook-codex.sh" vibeguard-pre-bash-guard.sh
)"
assert_contains "${rewrite_out}" '"systemMessage"' "run-hook-codex emits an explicit note for unsupported rewrites"
assert_contains "${rewrite_out}" 'pnpm install' "run-hook-codex includes the suggested rewritten command"
assert_codex_pretool_output_contract "${rewrite_out}" "rewrite advisory matches Codex PreToolUse output contract"

header "run-hook-codex maps Claude PreToolUse blocks to Codex deny schema"
cat > "${TMP_FAKE_REPO}/hooks/vibeguard-pre-bash-guard.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
printf '{"decision":"block","reason":"force push denied"}\n'
HOOK
chmod +x "${TMP_FAKE_REPO}/hooks/vibeguard-pre-bash-guard.sh"

pretool_block_out="$(
  printf '{"hook_event_name":"PreToolUse","tool_input":{"command":"git push --force"}}' \
    | HOME="${TMP_HOME}" bash "${REPO_DIR}/hooks/run-hook-codex.sh" vibeguard-pre-bash-guard.sh
)"
assert_contains "${pretool_block_out}" '"permissionDecision": "deny"' "run-hook-codex maps Claude block to Codex permission deny"
assert_contains "${pretool_block_out}" '"permissionDecisionReason": "force push denied"' "run-hook-codex preserves deny reason for Codex"
assert_codex_pretool_output_contract "${pretool_block_out}" "mapped pretool block matches Codex PreToolUse output contract"

header "run-hook-codex passes through pretool additional context"
cat > "${TMP_FAKE_REPO}/hooks/vibeguard-pre-bash-guard.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"advisory context"}}\n'
HOOK
chmod +x "${TMP_FAKE_REPO}/hooks/vibeguard-pre-bash-guard.sh"

pretool_context_out="$(
  printf '{"hook_event_name":"PreToolUse","tool_input":{"command":"printf x > notes.md"}}' \
    | HOME="${TMP_HOME}" bash "${REPO_DIR}/hooks/run-hook-codex.sh" vibeguard-pre-bash-guard.sh
)"
assert_contains "${pretool_context_out}" '"hookSpecificOutput"' "run-hook-codex passes through pretool hookSpecificOutput"
assert_contains "${pretool_context_out}" 'advisory context' "run-hook-codex preserves pretool additional context"
assert_codex_pretool_output_contract "${pretool_context_out}" "pretool additional context matches Codex PreToolUse output contract"

header "run-hook-codex keeps pass-with-no-output silent"
TMP_HOME_PASSING="${TMP_DIR}/home-passing"
TMP_FAKE_REPO_PASSING="${TMP_DIR}/fake-repo-passing"
PASSING_DIAG_FILE="${TMP_DIR}/passing-codex-wrapper.jsonl"
mkdir -p "${TMP_HOME_PASSING}/.vibeguard" "${TMP_FAKE_REPO_PASSING}/hooks"
printf '%s' "${TMP_FAKE_REPO_PASSING}" > "${TMP_HOME_PASSING}/.vibeguard/repo-path"

cat > "${TMP_FAKE_REPO_PASSING}/hooks/vibeguard-pre-bash-guard.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
exit 0
HOOK
chmod +x "${TMP_FAKE_REPO_PASSING}/hooks/vibeguard-pre-bash-guard.sh"

passing_out="$({
  printf '{"hook_event_name":"PreToolUse","tool_input":{"command":"echo ok"}}' \
    | HOME="${TMP_HOME_PASSING}" VIBEGUARD_CODEX_DIAG_FILE="${PASSING_DIAG_FILE}" bash "${REPO_DIR}/hooks/run-hook-codex.sh" vibeguard-pre-bash-guard.sh
} 2>/dev/null)"
TOTAL=$((TOTAL + 1))
if [[ -z "${passing_out}" ]]; then
  green "run-hook-codex keeps empty pass responses silent"
  PASS=$((PASS + 1))
else
  red "run-hook-codex keeps empty pass responses silent"
  FAIL=$((FAIL + 1))
fi
assert_contains "$(cat "${PASSING_DIAG_FILE}")" '"status": "running"' "run-hook-codex writes running status for pass hooks"
assert_contains "$(cat "${PASSING_DIAG_FILE}")" '"status": "pass"' "run-hook-codex writes pass status without stdout noise"

header "run-hook-codex denies wrapped hook failures instead of passing silently"
TMP_HOME_FAILING="${TMP_DIR}/home-failing"
TMP_FAKE_REPO_FAILING="${TMP_DIR}/fake-repo-failing"
mkdir -p "${TMP_HOME_FAILING}/.vibeguard" "${TMP_FAKE_REPO_FAILING}/hooks"
printf '%s' "${TMP_FAKE_REPO_FAILING}" > "${TMP_HOME_FAILING}/.vibeguard/repo-path"

cat > "${TMP_FAKE_REPO_FAILING}/hooks/vibeguard-pre-bash-guard.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
printf 'boom on stderr\n' >&2
exit 1
HOOK
chmod +x "${TMP_FAKE_REPO_FAILING}/hooks/vibeguard-pre-bash-guard.sh"

set +e
failing_out="$({
  printf '{"hook_event_name":"PreToolUse","tool_input":{"command":"rm -rf /"}}' \
    | HOME="${TMP_HOME_FAILING}" bash "${REPO_DIR}/hooks/run-hook-codex.sh" vibeguard-pre-bash-guard.sh
} 2>/dev/null)"
failing_rc=$?
set -e
assert_contains "${failing_out}" '"permissionDecision": "deny"' "run-hook-codex emits a deny payload when the wrapped hook exits nonzero"
assert_contains "${failing_out}" 'hook failed' "run-hook-codex explains wrapped hook failures"
assert_not_contains "${failing_out}" '"permissionDecision":"allow"' "run-hook-codex does not convert wrapped hook failure into allow"
assert_codex_pretool_output_contract "${failing_out}" "wrapped hook failure deny matches Codex PreToolUse output contract"
TOTAL=$((TOTAL + 1))
if [[ ${failing_rc} -eq 0 ]]; then
  green "run-hook-codex exits successfully when it emits a deny payload for wrapped hook failure"
  PASS=$((PASS + 1))
else
  red "run-hook-codex exits successfully when it emits a deny payload for wrapped hook failure"
  FAIL=$((FAIL + 1))
fi

header "run-hook-codex surfaces failed stop hooks without shell failure"
TMP_HOME_STOP_FAILING="${TMP_DIR}/home-stop-failing"
TMP_FAKE_REPO_STOP_FAILING="${TMP_DIR}/fake-repo-stop-failing"
mkdir -p "${TMP_HOME_STOP_FAILING}/.vibeguard" "${TMP_FAKE_REPO_STOP_FAILING}/hooks"
printf '%s' "${TMP_FAKE_REPO_STOP_FAILING}" > "${TMP_HOME_STOP_FAILING}/.vibeguard/repo-path"

cat > "${TMP_FAKE_REPO_STOP_FAILING}/hooks/vibeguard-stop-guard.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
printf 'transient stop failure\n' >&2
exit 1
HOOK
chmod +x "${TMP_FAKE_REPO_STOP_FAILING}/hooks/vibeguard-stop-guard.sh"

set +e
stop_out="$({
  printf '{"hook_event_name":"Stop"}' \
    | HOME="${TMP_HOME_STOP_FAILING}" bash "${REPO_DIR}/hooks/run-hook-codex.sh" vibeguard-stop-guard.sh
} 2>/dev/null)"
stop_rc=$?
set -e
TOTAL=$((TOTAL + 1))
if [[ ${stop_rc} -eq 0 ]]; then
  green "run-hook-codex exits successfully after reporting failed stop hooks"
  PASS=$((PASS + 1))
else
  red "run-hook-codex exits successfully after reporting failed stop hooks"
  FAIL=$((FAIL + 1))
fi
assert_contains "${stop_out}" '"stopReason"' "run-hook-codex emits visible Stop feedback on wrapped hook failure"
assert_contains "${stop_out}" 'wrapped hook exited nonzero' "run-hook-codex explains failed Stop hook"

header "run-hook-codex denies invalid pretool adapter output on any adapter failure"
TMP_HOME_INVALID_JSON="${TMP_DIR}/home-invalid-json"
TMP_FAKE_REPO_INVALID_JSON="${TMP_DIR}/fake-repo-invalid-json"
mkdir -p "${TMP_HOME_INVALID_JSON}/.vibeguard" "${TMP_FAKE_REPO_INVALID_JSON}/hooks"
printf '%s' "${TMP_FAKE_REPO_INVALID_JSON}" > "${TMP_HOME_INVALID_JSON}/.vibeguard/repo-path"

cat > "${TMP_FAKE_REPO_INVALID_JSON}/hooks/vibeguard-pre-bash-guard.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
printf '{'
HOOK
chmod +x "${TMP_FAKE_REPO_INVALID_JSON}/hooks/vibeguard-pre-bash-guard.sh"

set +e
invalid_json_out="$({
  printf '{"hook_event_name":"PreToolUse","tool_input":{"command":"git push --force"}}' \
    | HOME="${TMP_HOME_INVALID_JSON}" bash "${REPO_DIR}/hooks/run-hook-codex.sh" vibeguard-pre-bash-guard.sh
} 2>/dev/null)"
invalid_json_rc=$?
set -e
assert_contains "${invalid_json_out}" '"permissionDecision": "deny"' "run-hook-codex emits a deny payload when pretool adaptation fails"
assert_contains "${invalid_json_out}" 'invalid JSON' "run-hook-codex explains invalid pretool hook JSON"
assert_codex_pretool_output_contract "${invalid_json_out}" "invalid JSON deny matches Codex PreToolUse output contract"
TOTAL=$((TOTAL + 1))
if [[ ${invalid_json_rc} -eq 0 ]]; then
  green "run-hook-codex exits successfully when it emits a deny payload on pretool adapter failure"
  PASS=$((PASS + 1))
else
  red "run-hook-codex exits successfully when it emits a deny payload on pretool adapter failure"
  FAIL=$((FAIL + 1))
fi

header "run-hook-codex writes diagnostics without noisy stdout"
TMP_HOME_DIAG="${TMP_DIR}/home-diagnostics"
TMP_FAKE_REPO_DIAG="${TMP_DIR}/fake-repo-diagnostics"
DIAG_FILE="${TMP_DIR}/codex-wrapper.jsonl"
mkdir -p "${TMP_HOME_DIAG}/.vibeguard" "${TMP_FAKE_REPO_DIAG}/hooks"
printf '%s' "${TMP_FAKE_REPO_DIAG}" > "${TMP_HOME_DIAG}/.vibeguard/repo-path"

non_namespaced_out="$({
  printf '{"hook_event_name":"PreToolUse","tool_input":{"command":"echo ok"}}' \
    | HOME="${TMP_HOME_DIAG}" VIBEGUARD_CODEX_DIAG_FILE="${DIAG_FILE}" bash "${REPO_DIR}/hooks/run-hook-codex.sh" pre-bash-guard.sh
} 2>/dev/null)"
TOTAL=$((TOTAL + 1))
if [[ -z "${non_namespaced_out}" ]]; then
  green "non-namespaced hook remains stdout-silent"
  PASS=$((PASS + 1))
else
  red "non-namespaced hook remains stdout-silent"
  FAIL=$((FAIL + 1))
fi
assert_contains "$(cat "${DIAG_FILE}")" "non-namespaced-hook" "non-namespaced hook writes diagnostic event"

missing_hook_out="$(
  printf '{"hook_event_name":"PreToolUse","tool_input":{"command":"echo ok"}}' \
    | HOME="${TMP_HOME_DIAG}" VIBEGUARD_CODEX_DIAG_FILE="${DIAG_FILE}" bash "${REPO_DIR}/hooks/run-hook-codex.sh" vibeguard-pre-bash-guard.sh
)"
assert_contains "${missing_hook_out}" '"permissionDecision": "deny"' "missing PreToolUse hook fails closed"
assert_codex_pretool_output_contract "${missing_hook_out}" "missing hook deny matches Codex PreToolUse output contract"
assert_contains "$(cat "${DIAG_FILE}")" "missing-hook" "missing hook writes diagnostic event"

cat > "${TMP_FAKE_REPO_DIAG}/hooks/vibeguard-pre-bash-guard.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
exit 0
HOOK
chmod +x "${TMP_FAKE_REPO_DIAG}/hooks/vibeguard-pre-bash-guard.sh"
missing_adapter_out="$(
  printf '{"hook_event_name":"PreToolUse","tool_input":{"command":"echo ok"}}' \
    | HOME="${TMP_HOME_DIAG}" VIBEGUARD_CODEX_ADAPTER_PATH="${TMP_DIR}/missing-adapter.sh" VIBEGUARD_CODEX_DIAG_FILE="${DIAG_FILE}" bash "${REPO_DIR}/hooks/run-hook-codex.sh" vibeguard-pre-bash-guard.sh
)"
assert_contains "${missing_adapter_out}" '"permissionDecision": "deny"' "missing adapter fails closed for PreToolUse"
assert_codex_pretool_output_contract "${missing_adapter_out}" "missing adapter deny matches Codex PreToolUse output contract"
assert_contains "$(cat "${DIAG_FILE}")" "missing-adapter" "missing adapter writes diagnostic event"

missing_posttool_hook_out="$(
  printf '{"hook_event_name":"PostToolUse","tool_input":{"file_path":"src/main.ts"}}' \
    | HOME="${TMP_HOME_DIAG}" VIBEGUARD_CODEX_DIAG_FILE="${DIAG_FILE}" bash "${REPO_DIR}/hooks/run-hook-codex.sh" vibeguard-post-edit-guard.sh
)"
assert_contains "${missing_posttool_hook_out}" '"decision": "block"' "missing PostToolUse hook emits visible feedback"
assert_codex_posttool_output_contract "${missing_posttool_hook_out}" "missing PostToolUse hook output matches Codex contract"

cat > "${TMP_FAKE_REPO_DIAG}/hooks/vibeguard-post-edit-guard.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
exit 0
HOOK
chmod +x "${TMP_FAKE_REPO_DIAG}/hooks/vibeguard-post-edit-guard.sh"
missing_posttool_adapter_out="$(
  printf '{"hook_event_name":"PostToolUse","tool_input":{"file_path":"src/main.ts"}}' \
    | HOME="${TMP_HOME_DIAG}" VIBEGUARD_CODEX_ADAPTER_PATH="${TMP_DIR}/missing-adapter.sh" VIBEGUARD_CODEX_DIAG_FILE="${DIAG_FILE}" bash "${REPO_DIR}/hooks/run-hook-codex.sh" vibeguard-post-edit-guard.sh
)"
assert_contains "${missing_posttool_adapter_out}" '"decision": "block"' "missing PostToolUse adapter emits visible feedback"
assert_codex_posttool_output_contract "${missing_posttool_adapter_out}" "missing PostToolUse adapter output matches Codex contract"


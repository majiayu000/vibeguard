#!/usr/bin/env bash
# VibeGuard Codex runtime regression tests
#
# Usage: bash tests/test_codex_runtime.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

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

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

header "build Rust vibeguard-runtime"
if command -v cargo >/dev/null 2>&1; then
  cargo build --manifest-path "${REPO_DIR}/vibeguard-runtime/Cargo.toml" --quiet
  VIBEGUARD_RUNTIME="${REPO_DIR}/vibeguard-runtime/target/debug/vibeguard-runtime"
  TOTAL=$((TOTAL + 1))
  if [[ -x "${VIBEGUARD_RUNTIME}" ]]; then
    green "vibeguard-runtime Rust binary builds"
    PASS=$((PASS + 1))
  else
    red "vibeguard-runtime Rust binary builds"
    FAIL=$((FAIL + 1))
  fi
else
  red "cargo is required for Rust Codex wrapper tests"
  exit 1
fi

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

header "run-hook-codex keeps pass-with-no-output silent"
TMP_HOME_PASSING="${TMP_DIR}/home-passing"
TMP_FAKE_REPO_PASSING="${TMP_DIR}/fake-repo-passing"
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
    | HOME="${TMP_HOME_PASSING}" bash "${REPO_DIR}/hooks/run-hook-codex.sh" vibeguard-pre-bash-guard.sh
} 2>/dev/null)"
TOTAL=$((TOTAL + 1))
if [[ -z "${passing_out}" ]]; then
  green "run-hook-codex keeps empty pass responses silent"
  PASS=$((PASS + 1))
else
  red "run-hook-codex keeps empty pass responses silent"
  FAIL=$((FAIL + 1))
fi

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
TOTAL=$((TOTAL + 1))
if [[ ${failing_rc} -eq 0 ]]; then
  green "run-hook-codex exits successfully when it emits a deny payload for wrapped hook failure"
  PASS=$((PASS + 1))
else
  red "run-hook-codex exits successfully when it emits a deny payload for wrapped hook failure"
  FAIL=$((FAIL + 1))
fi

header "run-hook-codex keeps best-effort stop hooks non-blocking"
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
  green "run-hook-codex swallows nonzero exits for best-effort stop hooks"
  PASS=$((PASS + 1))
else
  red "run-hook-codex swallows nonzero exits for best-effort stop hooks"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
if [[ -z "${stop_out}" ]]; then
  green "run-hook-codex keeps failed best-effort stop hooks silent"
  PASS=$((PASS + 1))
else
  red "run-hook-codex keeps failed best-effort stop hooks silent"
  FAIL=$((FAIL + 1))
fi

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
assert_contains "$(cat "${DIAG_FILE}")" "missing-adapter" "missing adapter writes diagnostic event"

header "run-hook-codex adapts posttool block output"
TMP_HOME_POSTTOOL="${TMP_DIR}/home-posttool"
TMP_FAKE_REPO_POSTTOOL="${TMP_DIR}/fake-repo-posttool"
mkdir -p "${TMP_HOME_POSTTOOL}/.vibeguard" "${TMP_FAKE_REPO_POSTTOOL}/hooks"
printf '%s' "${TMP_FAKE_REPO_POSTTOOL}" > "${TMP_HOME_POSTTOOL}/.vibeguard/repo-path"

cat > "${TMP_FAKE_REPO_POSTTOOL}/hooks/vibeguard-post-build-check.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
printf '{"decision":"block","reason":"build failed"}\n'
HOOK
chmod +x "${TMP_FAKE_REPO_POSTTOOL}/hooks/vibeguard-post-build-check.sh"

posttool_out="$(
  printf '{"hook_event_name":"PostToolUse","tool_input":{"file_path":"src/main.rs"}}' \
    | HOME="${TMP_HOME_POSTTOOL}" bash "${REPO_DIR}/hooks/run-hook-codex.sh" vibeguard-post-build-check.sh
)"
assert_contains "${posttool_out}" '"decision": "block"' "run-hook-codex preserves posttool block decisions"
assert_contains "${posttool_out}" '"additionalContext": "build failed"' "run-hook-codex maps posttool reason to additionalContext"

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
TOTAL=$((TOTAL + 1))
if [[ -z "${bad_posttool_out}" ]]; then
  green "invalid PostToolUse hook output stays stdout-silent"
  PASS=$((PASS + 1))
else
  red "invalid PostToolUse hook output stays stdout-silent"
  FAIL=$((FAIL + 1))
fi
assert_contains "$(cat "${posttool_bad_diag}")" "posttool-adapter-failed" "invalid PostToolUse output writes diagnostic event"

run_wrapper() {
  local app_repo="$1"
  local child_script="$2"
  local input="$3"
  printf '%b\n' "${input}" | "${VIBEGUARD_RUNTIME}" codex-app-server-wrapper \
    --repo-dir "${app_repo}" \
    --codex-command "bash '${child_script}'"
}

header "Rust app-server wrapper rewrites approved commands"
APP_REPO_REWRITE="${TMP_DIR}/app-server-rewrite"
mkdir -p "${APP_REPO_REWRITE}/hooks"
cat > "${APP_REPO_REWRITE}/hooks/pre-bash-guard.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
printf '{"decision":"allow","updatedInput":{"command":"rewrite=%s|%s|%s"}}\n' \
  "${VIBEGUARD_SESSION_ID:-}" "${VIBEGUARD_THREAD_ID:-}" "${VIBEGUARD_TURN_ID:-}"
HOOK
chmod +x "${APP_REPO_REWRITE}/hooks/pre-bash-guard.sh"
cat > "${TMP_DIR}/child-rewrite.sh" <<'CHILD'
#!/usr/bin/env bash
IFS= read -r _thread_start
IFS= read -r _turn_start
printf '{"id":"req-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread/alpha","command":"npm install"}}\n'
IFS= read -r response
printf '%s\n' "$response"
CHILD
chmod +x "${TMP_DIR}/child-rewrite.sh"
rewrite_json="$(run_wrapper "${APP_REPO_REWRITE}" "${TMP_DIR}/child-rewrite.sh" $'{"method":"thread/start","params":{"threadId":"thread/alpha","cwd":"'"${APP_REPO_REWRITE}"'"}}\n{"method":"turn/start","params":{"threadId":"thread/alpha","cwd":"'"${APP_REPO_REWRITE}"'","turnId":"turn-42"}}')"
assert_contains "${rewrite_json}" '"decision":"approve"' "Rust wrapper intercepts rewritten command approvals"
assert_contains "${rewrite_json}" 'rewrite=codex-thread-thread-alpha-' "Rust wrapper passes normalized session id to hooks"
assert_contains "${rewrite_json}" '|thread/alpha|turn-42' "Rust wrapper passes thread and turn context to hooks"

header "Rust app-server wrapper fails closed on pre-bash hook failure"
APP_REPO_FAIL="${TMP_DIR}/app-server-fail"
mkdir -p "${APP_REPO_FAIL}/hooks"
cat > "${APP_REPO_FAIL}/hooks/pre-bash-guard.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
printf 'boom on stderr\n' >&2
exit 1
HOOK
chmod +x "${APP_REPO_FAIL}/hooks/pre-bash-guard.sh"
cat > "${TMP_DIR}/child-fail.sh" <<'CHILD'
#!/usr/bin/env bash
IFS= read -r _thread_start
printf '{"id":"req-fail","method":"item/commandExecution/requestApproval","params":{"threadId":"thread/fail","command":"rm -rf /"}}\n'
IFS= read -r response
printf '%s\n' "$response"
IFS= read -r warning
printf '%s\n' "$warning"
CHILD
chmod +x "${TMP_DIR}/child-fail.sh"
failure_json="$(run_wrapper "${APP_REPO_FAIL}" "${TMP_DIR}/child-fail.sh" $'{"method":"thread/start","params":{"threadId":"thread/fail","cwd":"'"${APP_REPO_FAIL}"'"}}' 2>/dev/null)"
assert_contains "${failure_json}" '"decision":"decline"' "Rust wrapper declines commands when pre-bash hook exits nonzero"
assert_contains "${failure_json}" 'boom on stderr' "Rust wrapper emits failed hook details as warning context"

header "Rust app-server wrapper declines blocked file changes"
APP_REPO_FILE_BLOCK="${TMP_DIR}/app-server-file-block"
mkdir -p "${APP_REPO_FILE_BLOCK}/hooks"
cat > "${APP_REPO_FILE_BLOCK}/hooks/pre-write-guard.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
printf '{"decision":"block","reason":"blocked source write"}\n'
HOOK
chmod +x "${APP_REPO_FILE_BLOCK}/hooks/pre-write-guard.sh"
cat > "${TMP_DIR}/child-file-block.sh" <<'CHILD'
#!/usr/bin/env bash
IFS= read -r _thread_start
IFS= read -r _turn_start
printf '%s\n' '{"method":"item/fileChange/patchUpdated","params":{"threadId":"thread/file","turnId":"turn-file","itemId":"item-block","changes":[{"path":"blocked.py","kind":"add","diff":"@@\n+print('\''x'\'')\n"}]}}'
printf '%s\n' '{"id":"req-file-block","method":"item/fileChange/requestApproval","params":{"threadId":"thread/file","turnId":"turn-file","itemId":"item-block"}}'
IFS= read -r response
printf '%s\n' "$response"
IFS= read -r warning
printf '%s\n' "$warning"
CHILD
chmod +x "${TMP_DIR}/child-file-block.sh"
file_block_json="$(run_wrapper "${APP_REPO_FILE_BLOCK}" "${TMP_DIR}/child-file-block.sh" $'{"method":"thread/start","params":{"threadId":"thread/file","cwd":"'"${APP_REPO_FILE_BLOCK}"'"}}\n{"method":"turn/start","params":{"threadId":"thread/file","cwd":"'"${APP_REPO_FILE_BLOCK}"'","turnId":"turn-file"}}' 2>/dev/null)"
assert_contains "${file_block_json}" '"decision":"decline"' "Rust wrapper declines blocked file approvals"
assert_contains "${file_block_json}" 'blocked source write' "Rust wrapper emits file guard blocking reason"

header "Rust app-server wrapper forwards post-write warnings"
APP_REPO_FILE_WARN="${TMP_DIR}/app-server-file-warn"
mkdir -p "${APP_REPO_FILE_WARN}/hooks"
cat > "${APP_REPO_FILE_WARN}/hooks/pre-write-guard.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
HOOK
cat > "${APP_REPO_FILE_WARN}/hooks/post-write-guard.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"duplicate implementation found"}}\n'
HOOK
chmod +x "${APP_REPO_FILE_WARN}/hooks/pre-write-guard.sh" "${APP_REPO_FILE_WARN}/hooks/post-write-guard.sh"
cat > "${TMP_DIR}/child-file-warn.sh" <<'CHILD'
#!/usr/bin/env bash
IFS= read -r _thread_start
IFS= read -r _turn_start
printf '%s\n' '{"method":"item/fileChange/patchUpdated","params":{"threadId":"thread/file-warn","turnId":"turn-file-warn","itemId":"item-warn","changes":[{"path":"new_source.py","kind":"add","diff":"@@\n+print('\''x'\'')\n"}]}}'
printf '%s\n' '{"id":"req-file-warn","method":"item/fileChange/requestApproval","params":{"threadId":"thread/file-warn","turnId":"turn-file-warn","itemId":"item-warn"}}'
IFS= read -r warning
printf '%s\n' "$warning"
CHILD
chmod +x "${TMP_DIR}/child-file-warn.sh"
file_warn_json="$(run_wrapper "${APP_REPO_FILE_WARN}" "${TMP_DIR}/child-file-warn.sh" $'{"method":"thread/start","params":{"threadId":"thread/file-warn","cwd":"'"${APP_REPO_FILE_WARN}"'"}}\n{"method":"turn/start","params":{"threadId":"thread/file-warn","cwd":"'"${APP_REPO_FILE_WARN}"'","turnId":"turn-file-warn"}}')"
assert_contains "${file_warn_json}" '"method":"item/fileChange/requestApproval"' "Rust wrapper forwards non-blocked file approval requests"
assert_contains "${file_warn_json}" 'duplicate implementation found' "Rust wrapper forwards post-write warning context"
assert_not_contains "${file_warn_json}" '"decision":"decline"' "Post-write warnings do not decline approvals"

header "Rust app-server wrapper denies blocked applyPatch edits"
APP_REPO_PATCH="${TMP_DIR}/app-server-patch"
mkdir -p "${APP_REPO_PATCH}/hooks"
printf 'old\n' > "${APP_REPO_PATCH}/target.py"
cat > "${APP_REPO_PATCH}/hooks/pre-edit-guard.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
printf '{"decision":"block","reason":"blocked edit"}\n'
HOOK
chmod +x "${APP_REPO_PATCH}/hooks/pre-edit-guard.sh"
cat > "${TMP_DIR}/child-patch.sh" <<'CHILD'
#!/usr/bin/env bash
IFS= read -r _thread_start
printf '%s\n' '{"id":"req-apply-patch","method":"applyPatchApproval","params":{"conversationId":"thread/patch","fileChanges":{"target.py":{"type":"update","unified_diff":"--- a/target.py\n+++ b/target.py\n@@\n-old\n+new\n","move_path":null}}}}'
IFS= read -r response
printf '%s\n' "$response"
IFS= read -r warning
printf '%s\n' "$warning"
CHILD
chmod +x "${TMP_DIR}/child-patch.sh"
patch_json="$(run_wrapper "${APP_REPO_PATCH}" "${TMP_DIR}/child-patch.sh" $'{"method":"thread/start","params":{"threadId":"thread/patch","cwd":"'"${APP_REPO_PATCH}"'"}}' 2>/dev/null)"
assert_contains "${patch_json}" '"decision":"denied"' "Rust wrapper maps guarded applyPatch blocks to denied"
assert_contains "${patch_json}" 'blocked edit' "Rust wrapper emits applyPatch blocking reason"

header "Rust app-server wrapper maps multi-hunk diffs to edit-sized payloads"
APP_REPO_MULTI="${TMP_DIR}/app-server-multi"
mkdir -p "${APP_REPO_MULTI}/hooks"
printf 'one\ntwo\nthree\nfour\nfive\nsix\n' > "${APP_REPO_MULTI}/target.py"
cat > "${APP_REPO_MULTI}/hooks/pre-edit-guard.sh" <<'HOOK'
#!/usr/bin/env bash
payload=$(cat)
case "$payload" in
  *'one\ntwo\nthree'*|*'four\nfive\nsix'*) ;;
  *) printf '{"decision":"block","reason":"bad old_string"}\n' ;;
esac
HOOK
cat > "${APP_REPO_MULTI}/hooks/post-edit-guard.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
HOOK
chmod +x "${APP_REPO_MULTI}/hooks/pre-edit-guard.sh" "${APP_REPO_MULTI}/hooks/post-edit-guard.sh"
cat > "${TMP_DIR}/child-multi.sh" <<'CHILD'
#!/usr/bin/env bash
IFS= read -r _thread_start
printf '%s\n' '{"id":"req-multi","method":"applyPatchApproval","params":{"conversationId":"thread/multi","fileChanges":{"target.py":{"type":"update","unified_diff":"--- a/target.py\n+++ b/target.py\n@@\n one\n-two\n+TWO\n three\n@@\n four\n-five\n+FIVE\n six\n","move_path":null}}}}'
if IFS= read -r -t 1 maybe_response; then
  printf '%s\n' "$maybe_response"
fi
CHILD
chmod +x "${TMP_DIR}/child-multi.sh"
multi_json="$(run_wrapper "${APP_REPO_MULTI}" "${TMP_DIR}/child-multi.sh" $'{"method":"thread/start","params":{"threadId":"thread/multi","cwd":"'"${APP_REPO_MULTI}"'"}}')"
assert_contains "${multi_json}" '"method":"applyPatchApproval"' "Rust wrapper forwards valid multi-hunk applyPatch approval requests"
assert_not_contains "${multi_json}" 'bad old_string' "Rust wrapper does not join unrelated removed lines"

header "Rust app-server wrapper warns on analysis paralysis"
APP_REPO_READ_LOOP="${TMP_DIR}/app-server-read-loop"
mkdir -p "${APP_REPO_READ_LOOP}/hooks"
cat > "${APP_REPO_READ_LOOP}/hooks/pre-bash-guard.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
HOOK
chmod +x "${APP_REPO_READ_LOOP}/hooks/pre-bash-guard.sh"
cat > "${TMP_DIR}/child-read-loop.sh" <<'CHILD'
#!/usr/bin/env bash
IFS= read -r _thread_start
printf '{"id":"req-read-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread/read-loop","command":"rg TODO"}}\n'
printf '{"id":"req-read-2","method":"item/commandExecution/requestApproval","params":{"threadId":"thread/read-loop","command":"sed -n '\''1,40p'\'' README.md"}}\n'
IFS= read -r warning
printf '%s\n' "$warning"
CHILD
chmod +x "${TMP_DIR}/child-read-loop.sh"
analysis_json="$(VG_PARALYSIS_THRESHOLD=2 run_wrapper "${APP_REPO_READ_LOOP}" "${TMP_DIR}/child-read-loop.sh" $'{"method":"thread/start","params":{"threadId":"thread/read-loop","cwd":"'"${APP_REPO_READ_LOOP}"'"}}')"
assert_contains "${analysis_json}" '"method":"warning"' "Rust wrapper emits analysis-paralysis warning notification"
assert_contains "${analysis_json}" 'analysis paralysis warning' "Analysis warning explains read-only streak"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

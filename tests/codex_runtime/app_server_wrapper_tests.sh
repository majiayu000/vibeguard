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
# Exercise the wrapper's EOF drain path: CI can be slow enough that a final
# approval request arrives after the parent stdin has already closed.
sleep 0.4
printf '{"id":"req-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread/alpha","command":"npm install"}}\n'
IFS= read -r response
printf '%s\n' "$response"
CHILD
chmod +x "${TMP_DIR}/child-rewrite.sh"
rewrite_json="$(run_wrapper "${APP_REPO_REWRITE}" "${TMP_DIR}/child-rewrite.sh" $'{"method":"thread/start","params":{"threadId":"thread/alpha","cwd":"'"${APP_REPO_REWRITE}"'"}}\n{"method":"turn/start","params":{"threadId":"thread/alpha","cwd":"'"${APP_REPO_REWRITE}"'","turnId":"turn-42"}}')"
assert_contains "${rewrite_json}" '"decision":"accept"' "Rust wrapper intercepts rewritten command approvals"
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
printf '%s\n' '{"method":"item/completed","params":{"threadId":"thread/file-warn","turnId":"turn-file-warn","item":{"id":"item-warn","type":"fileChange","status":"completed"}}}'
IFS= read -r forwarded
printf '%s\n' "$forwarded"
IFS= read -r completed
printf '%s\n' "$completed"
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

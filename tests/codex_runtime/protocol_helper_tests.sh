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

header "Codex protocol helpers use runtime without python3"
NO_PYTHON_BIN="${TMP_DIR}/no-python-bin"
mkdir -p "${NO_PYTHON_BIN}"
cat > "${NO_PYTHON_BIN}/python3" <<'SH'
#!/usr/bin/env bash
exit 99
SH
chmod +x "${NO_PYTHON_BIN}/python3"

protocol_helper_out="$(
  WRAPPER_DIR="${REPO_DIR}/hooks" PATH="${NO_PYTHON_BIN}:${PATH}" VIBEGUARD_CODEX_DIAG_FILE="${TMP_DIR}/protocol-codex-wrapper.jsonl" bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    payload="{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cargo test\"}}"
    printf "raw_event=%s\n" "$(codex_raw_event_name "${payload}")"
    printf "adapter_event=%s\n" "$(codex_event_name "${payload}")"
    printf "status_info=%s\n" "$(codex_hook_status_info "${payload}")"
    printf "matcher=%s\n" "$(codex_hook_status_matcher "${payload}")"
    printf "detail=%s\n" "$(codex_hook_status_detail "${payload}")"
    printf "start_info=%s\n" "$(codex_hook_start_info "${payload}" "vibeguard-pre-bash-guard.sh" "15000")"
    codex_hook_status() { printf "status=%s reason=%s\n" "$4" "$5"; }
    codex_hook_status_from_output "vibeguard-pre-bash-guard.sh" "PreToolUse" "Bash" "{\"hookSpecificOutput\":{\"decision\":{\"behavior\":\"deny\",\"message\":\"stop\"}}}"
    printf "finalize_start\n"; codex_finalize_output "vibeguard-pre-bash-guard.sh" "PreToolUse" "Bash" "{\"decision\":\"block\",\"reason\":\"finalized without python\"}" "cargo test" "15000"; printf "finalize_end\n"
    printf "status_json=%s\n" "$(cat "${VIBEGUARD_CODEX_DIAG_FILE}")"
    printf "pretool_deny_start\n"; codex_pretool_deny "blocked without python"; printf "pretool_deny_end\n"
    printf "permission_deny_start\n"; codex_permission_deny "permission blocked without python"; printf "permission_deny_end\n"
    printf "pretool_adapt_start\n"; codex_adapt_pretool "{\"decision\":\"block\",\"reason\":\"adapted without python\"}"; printf "pretool_adapt_end\n"
    printf "posttool_adapt_start\n"; codex_adapt_posttool "{\"decision\":\"block\",\"reason\":\"posttool without python\"}"; printf "posttool_adapt_end\n"
    printf "permission_adapt_start\n"; codex_adapt_permission_request "{\"decision\":\"block\",\"reason\":\"permission adapted without python\"}"; printf "permission_adapt_end\n"
  ' -- "${REPO_DIR}/hooks/_lib/codex_diag.sh" "${REPO_DIR}/hooks/_lib/codex_adapter.sh"
)"
assert_contains "${protocol_helper_out}" "raw_event=PreToolUse" "codex_raw_event_name works without python3"
assert_contains "${protocol_helper_out}" "adapter_event=PreToolUse" "codex_event_name works without python3"
assert_contains "${protocol_helper_out}" $'status_info=PreToolUse\tBash\tcargo test' "codex_hook_status_info works without python3"
assert_contains "${protocol_helper_out}" "matcher=Bash" "codex_hook_status_matcher works without python3"
assert_contains "${protocol_helper_out}" "detail=cargo test" "codex_hook_status_detail works without python3"
assert_contains "${protocol_helper_out}" $'start_info=PreToolUse\tBash\tcargo test' "codex_hook_start_info works without python3"
assert_contains "${protocol_helper_out}" '"status":"block"' "codex_hook_status_from_output works without python3"
assert_contains "${protocol_helper_out}" "finalized without python" "codex_finalize_output adapts output without python3"
assert_contains "${protocol_helper_out}" "blocked without python" "codex_pretool_deny works without python3"
assert_contains "${protocol_helper_out}" "permission blocked without python" "codex_permission_deny works without python3"
assert_contains "${protocol_helper_out}" "adapted without python" "codex_adapt_pretool works without python3"
assert_contains "${protocol_helper_out}" "posttool without python" "codex_adapt_posttool works without python3"
assert_contains "${protocol_helper_out}" "permission adapted without python" "codex_adapt_permission_request works without python3"

timeout_defaults_out="$(
  WRAPPER_DIR="${REPO_DIR}/hooks" bash -c '
    set -euo pipefail
    source "$1"
    printf "pre_bash=%s\n" "$(codex_hook_timeout_ms vibeguard-pre-bash-guard.sh)"
    printf "post_build=%s\n" "$(codex_hook_timeout_ms vibeguard-post-build-check.sh)"
    printf "stop=%s\n" "$(codex_hook_timeout_ms vibeguard-stop-guard.sh)"
  ' -- "${REPO_DIR}/hooks/_lib/codex_diag.sh"
)"
assert_contains "${timeout_defaults_out}" "pre_bash=15000" "Codex pre hooks use manifest timeout"
assert_contains "${timeout_defaults_out}" "post_build=35000" "Codex post-build hook uses manifest timeout"
assert_contains "${timeout_defaults_out}" "stop=15000" "Codex stop hook uses manifest timeout"

OLD_STATUS_RUNTIME="${TMP_DIR}/old-status-runtime"
OLD_STATUS_DIAG="${TMP_DIR}/old-status-diag.jsonl"
cat > "${OLD_STATUS_RUNTIME}" <<'SH'
#!/usr/bin/env bash
cmd="$1"
shift
case "$cmd" in
  codex-status-info|codex-hook-start|codex-hook-status-from-output|codex-finalize-output)
    printf 'Unknown command: %s\n' "$cmd" >&2
    exit 2
    ;;
  codex-event-name)
    cat >/dev/null
    printf 'PreToolUse\n'
    ;;
  codex-status-matcher)
    cat >/dev/null
    printf 'Bash\n'
    ;;
  codex-status-detail)
    cat >/dev/null
    printf 'cargo test\n'
    ;;
  codex-status-from-output)
    cat >/dev/null
    printf 'block\told-runtime-block\n'
    ;;
  codex-adapt-pretool)
    cat >/dev/null
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"old-runtime-adapted"}}\n'
    ;;
  codex-hook-status)
    diag_file="$1"
    hook_name="$2"
    event_name="$3"
    matcher="$4"
    status="$5"
    reason="$6"
    detail="$7"
    timeout_ms="$8"
    printf '{"hook":"%s","event":"%s","matcher":"%s","status":"%s","reason":"%s","detail":"%s","timeout_ms":%s}\n' \
      "$hook_name" "$event_name" "$matcher" "$status" "$reason" "$detail" "$timeout_ms" >> "$diag_file"
    ;;
  *)
    exit 2
    ;;
esac
SH
chmod +x "${OLD_STATUS_RUNTIME}"
old_status_out="$(
  WRAPPER_DIR="${REPO_DIR}/hooks" VIBEGUARD_RUNTIME="${OLD_STATUS_RUNTIME}" VIBEGUARD_CODEX_DIAG_FILE="${OLD_STATUS_DIAG}" bash -c '
    set -euo pipefail
    source "$1"
    payload="{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cargo test\"}}"
    printf "old_status_info=%s\n" "$(codex_hook_status_info "${payload}")"
    codex_hook_status_from_output "vibeguard-pre-bash-guard.sh" "PreToolUse" "Bash" "{\"decision\":\"block\",\"reason\":\"fallback\"}" "cargo test" "10000"
    printf "old_status_diag=%s\n" "$(cat "${VIBEGUARD_CODEX_DIAG_FILE}")"
  ' -- "${REPO_DIR}/hooks/_lib/codex_diag.sh"
)"
assert_contains "${old_status_out}" $'old_status_info=PreToolUse\tBash\tcargo test' "codex_hook_status_info falls back to old runtime helpers"
assert_contains "${old_status_out}" '"status":"block"' "codex_hook_status_from_output falls back to old runtime helpers"
assert_not_contains "${old_status_out}" "runtime-unavailable" "old runtime status fallback does not create false hook_error"

TMP_FAKE_REPO_OLD_RUNTIME="${TMP_DIR}/fake-repo-old-runtime"
mkdir -p "${TMP_FAKE_REPO_OLD_RUNTIME}/hooks"
cat > "${TMP_FAKE_REPO_OLD_RUNTIME}/hooks/vibeguard-pre-bash-guard.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
printf '{"decision":"block","reason":"old runner fallback"}\n'
HOOK
chmod +x "${TMP_FAKE_REPO_OLD_RUNTIME}/hooks/vibeguard-pre-bash-guard.sh"
old_runner_out="$(
  WRAPPER_DIR="${REPO_DIR}/hooks" VIBEGUARD_RUNTIME="${OLD_STATUS_RUNTIME}" VIBEGUARD_CODEX_DIAG_FILE="${TMP_DIR}/old-runner-diag.jsonl" bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    source "$3"
    EVENT_NAME=PreToolUse
    codex_run_hook "vibeguard-pre-bash-guard.sh" "$4" "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cargo test\"}}"
  ' -- \
    "${REPO_DIR}/hooks/_lib/codex_diag.sh" \
    "${REPO_DIR}/hooks/_lib/codex_adapter.sh" \
    "${REPO_DIR}/hooks/_lib/codex_runner.sh" \
    "${TMP_FAKE_REPO_OLD_RUNTIME}/hooks/vibeguard-pre-bash-guard.sh"
)"
assert_contains "${old_runner_out}" '"permissionDecision":"deny"' "codex_run_hook falls back when old runtime lacks batched helpers"
assert_contains "${old_runner_out}" "old-runtime-adapted" "old runtime fallback still adapts PreToolUse output"

COUNTING_RUNTIME="${TMP_DIR}/counting-vibeguard-runtime"
COUNTING_RUNTIME_LOG="${TMP_DIR}/counting-runtime.log"
: > "${COUNTING_RUNTIME_LOG}"
cat > "${COUNTING_RUNTIME}" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "${VIBEGUARD_RUNTIME_COUNT_LOG:?}"
exec "${VIBEGUARD_REAL_RUNTIME:?}" "$@"
SH
chmod +x "${COUNTING_RUNTIME}"
TMP_FAKE_REPO_COUNTING="${TMP_DIR}/fake-repo-counting-runtime"
mkdir -p "${TMP_FAKE_REPO_COUNTING}/hooks"
cat > "${TMP_FAKE_REPO_COUNTING}/hooks/vibeguard-pre-bash-guard.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
printf '{"decision":"block","reason":"counted block"}\n'
HOOK
chmod +x "${TMP_FAKE_REPO_COUNTING}/hooks/vibeguard-pre-bash-guard.sh"
COUNTING_REAL_RUNTIME="${VIBEGUARD_RUNTIME}"
counting_runner_out="$(
  WRAPPER_DIR="${REPO_DIR}/hooks" \
  VIBEGUARD_RUNTIME="${COUNTING_RUNTIME}" \
  VIBEGUARD_REAL_RUNTIME="${COUNTING_REAL_RUNTIME}" \
  VIBEGUARD_RUNTIME_COUNT_LOG="${COUNTING_RUNTIME_LOG}" \
  VIBEGUARD_CODEX_DIAG_FILE="${TMP_DIR}/counting-runner-diag.jsonl" \
  bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    source "$3"
    EVENT_NAME=PreToolUse
    codex_run_hook "vibeguard-pre-bash-guard.sh" "$4" "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cargo test\"}}"
    printf "runtime_count=%s\n" "$(wc -l < "${VIBEGUARD_RUNTIME_COUNT_LOG}" | tr -d " ")"
  ' -- \
    "${REPO_DIR}/hooks/_lib/codex_diag.sh" \
    "${REPO_DIR}/hooks/_lib/codex_adapter.sh" \
    "${REPO_DIR}/hooks/_lib/codex_runner.sh" \
    "${TMP_FAKE_REPO_COUNTING}/hooks/vibeguard-pre-bash-guard.sh"
)"
assert_contains "${counting_runner_out}" "counted block" "counting runtime path still blocks PreToolUse"
assert_contains "${counting_runner_out}" "runtime_count=2" "codex_run_hook uses two runtime spawns for normal non-empty PreToolUse output"

BROKEN_RUNTIME="${TMP_DIR}/broken-vibeguard-runtime"
cat > "${BROKEN_RUNTIME}" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "${BROKEN_RUNTIME}"
broken_runtime_deny_out="$(
  WRAPPER_DIR="${REPO_DIR}/hooks" VIBEGUARD_RUNTIME="${BROKEN_RUNTIME}" bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    codex_pretool_deny "pretool fallback reason"
    codex_permission_deny "permission fallback reason"
  ' -- "${REPO_DIR}/hooks/_lib/codex_diag.sh" "${REPO_DIR}/hooks/_lib/codex_adapter.sh"
)"
assert_contains "${broken_runtime_deny_out}" "pretool fallback reason" "codex_pretool_deny falls back when runtime exits nonzero"
assert_contains "${broken_runtime_deny_out}" "permission fallback reason" "codex_permission_deny falls back when runtime exits nonzero"

TMP_HOME_BROKEN_RUNTIME="${TMP_DIR}/home-broken-runtime"
TMP_FAKE_REPO_BROKEN_RUNTIME="${TMP_DIR}/fake-repo-broken-runtime"
mkdir -p "${TMP_HOME_BROKEN_RUNTIME}/.vibeguard" "${TMP_FAKE_REPO_BROKEN_RUNTIME}/hooks"
printf '%s' "${TMP_FAKE_REPO_BROKEN_RUNTIME}" > "${TMP_HOME_BROKEN_RUNTIME}/.vibeguard/repo-path"
cat > "${TMP_FAKE_REPO_BROKEN_RUNTIME}/hooks/vibeguard-pre-bash-guard.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
printf '{'
HOOK
chmod +x "${TMP_FAKE_REPO_BROKEN_RUNTIME}/hooks/vibeguard-pre-bash-guard.sh"
broken_runtime_wrapper_out="$(
  printf '{"hook_event_name":"PreToolUse","tool_input":{"command":"rm -rf /"}}' \
    | HOME="${TMP_HOME_BROKEN_RUNTIME}" VIBEGUARD_RUNTIME="${BROKEN_RUNTIME}" bash "${REPO_DIR}/hooks/run-hook-codex.sh" vibeguard-pre-bash-guard.sh
)"
assert_contains "${broken_runtime_wrapper_out}" '"permissionDecision":"deny"' "run-hook-codex still denies when adapter runtime exits nonzero"
assert_contains "${broken_runtime_wrapper_out}" 'wrapped hook output could not be adapted' "run-hook-codex explains broken adapter runtime fallback"

TMP_HOME_NO_PYTHON_PATCH="${TMP_DIR}/home-no-python-patch"
TMP_FAKE_REPO_NO_PYTHON_PATCH="${TMP_DIR}/fake-repo-no-python-patch"
mkdir -p "${TMP_HOME_NO_PYTHON_PATCH}/.vibeguard" "${TMP_FAKE_REPO_NO_PYTHON_PATCH}/hooks"
printf '%s' "${TMP_FAKE_REPO_NO_PYTHON_PATCH}" > "${TMP_HOME_NO_PYTHON_PATCH}/.vibeguard/repo-path"
cat > "${TMP_FAKE_REPO_NO_PYTHON_PATCH}/hooks/vibeguard-pre-write-guard.sh" <<'HOOK'
#!/usr/bin/env bash
input="$(cat)"
if [[ "${input}" == *'"tool_name":"Write"'* && "${input}" == *'src/no_python.rs'* ]]; then
  printf '{"decision":"block","reason":"apply_patch normalized without python"}\n'
else
  printf '{"decision":"pass"}\n'
fi
HOOK
chmod +x "${TMP_FAKE_REPO_NO_PYTHON_PATCH}/hooks/vibeguard-pre-write-guard.sh"
no_python_patch_payload='{"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Add File: src/no_python.rs\n+fn main() {}\n*** End Patch"}}'
no_python_patch_out="$(
  WRAPPER_DIR="${REPO_DIR}/hooks" PATH="${NO_PYTHON_BIN}:${PATH}" VIBEGUARD_RUNTIME="${VIBEGUARD_RUNTIME}" bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    source "$3"
    EVENT_NAME=PreToolUse
    codex_diag() { return 0; }
    codex_hook_status() { return 0; }
    codex_run_hook "vibeguard-pre-write-guard.sh" "$4" "$5"
  ' -- \
    "${REPO_DIR}/hooks/_lib/codex_diag.sh" \
    "${REPO_DIR}/hooks/_lib/codex_adapter.sh" \
    "${REPO_DIR}/hooks/_lib/codex_runner.sh" \
    "${TMP_FAKE_REPO_NO_PYTHON_PATCH}/hooks/vibeguard-pre-write-guard.sh" \
    "${no_python_patch_payload}"
)"
assert_contains "${no_python_patch_out}" '"permissionDecision": "deny"' "codex_run_hook apply_patch normalizer works without python3"
assert_contains "${no_python_patch_out}" 'apply_patch normalized without python' "codex_run_hook apply_patch path reaches normalized Write hook without python3"

TMP_FAKE_REPO_TIMEOUT="${TMP_DIR}/fake-repo-timeout"
mkdir -p "${TMP_FAKE_REPO_TIMEOUT}/hooks"
cat > "${TMP_FAKE_REPO_TIMEOUT}/hooks/vibeguard-pre-bash-guard.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
sleep 5
printf '{"decision":"pass"}\n'
HOOK
chmod +x "${TMP_FAKE_REPO_TIMEOUT}/hooks/vibeguard-pre-bash-guard.sh"
timeout_out="$(
  WRAPPER_DIR="${REPO_DIR}/hooks" VIBEGUARD_RUNTIME="${VIBEGUARD_RUNTIME}" bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    source "$3"
    source "$4"
    EVENT_NAME=PreToolUse
    codex_diag() { printf "diag=%s:%s\n" "$3" "$4"; }
    codex_hook_status() { printf "status=%s reason=%s timeout=%s\n" "$4" "$5" "$7"; }
    codex_hook_timeout_ms() { printf "100\n"; }
    codex_run_hook "vibeguard-pre-bash-guard.sh" "$5" "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sleep 5\"}}"
  ' -- \
    "${REPO_DIR}/hooks/_lib/codex_diag.sh" \
    "${REPO_DIR}/hooks/_lib/codex_adapter.sh" \
    "${REPO_DIR}/hooks/_lib/timeout.sh" \
    "${REPO_DIR}/hooks/_lib/codex_runner.sh" \
    "${TMP_FAKE_REPO_TIMEOUT}/hooks/vibeguard-pre-bash-guard.sh"
)"
assert_contains "${timeout_out}" "status=timeout" "codex_run_hook enforces wrapped hook timeout"
assert_contains "${timeout_out}" "wrapped-hook-timeout" "codex_run_hook records timeout diagnostic"
assert_contains "${timeout_out}" "VIBEGUARD hook timed out" "codex_run_hook emits visible timeout failure"

timeout_fast_started="$(date +%s)"
timeout_fast_out="$(
  bash -c '
    set -euo pipefail
    source "$1"
    vg_run_with_timeout 3 bash -c "exit 0"
  ' -- "${REPO_DIR}/hooks/_lib/timeout.sh"
)"
timeout_fast_elapsed=$(( $(date +%s) - timeout_fast_started ))
TOTAL=$((TOTAL + 1))
if [[ "${timeout_fast_elapsed}" -lt 3 ]]; then
  green "timeout fallback returns before the deadline for fast commands"
  PASS=$((PASS + 1))
else
  red "timeout fallback returns before the deadline for fast commands"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
if [[ -z "${timeout_fast_out}" ]]; then
  green "timeout fallback keeps fast command stdout empty"
  PASS=$((PASS + 1))
else
  red "timeout fallback keeps fast command stdout empty"
  FAIL=$((FAIL + 1))
fi

NO_TIMEOUT_BIN="${TMP_DIR}/no-timeout-bin"
mkdir -p "${NO_TIMEOUT_BIN}"
for _tool in bash cat mktemp pgrep sleep yes; do
  _tool_path="$(command -v "${_tool}")"
  ln -s "${_tool_path}" "${NO_TIMEOUT_BIN}/${_tool}"
done

timeout_stdin_out="$(
  bash -c '
    set -euo pipefail
    PATH="$1"
    source "$2"
    printf "abc\n" | vg_run_with_timeout 2 bash -c '"'"'IFS= read -r line || true; printf "line=%s\n" "$line"'"'"'
  ' -- "${NO_TIMEOUT_BIN}" "${REPO_DIR}/hooks/_lib/timeout.sh"
)"
assert_contains "${timeout_stdin_out}" "line=abc" "timeout fallback preserves pipeline stdin"

timeout_unclosed_stdin_started="$(date +%s)"
timeout_unclosed_stdin_out="$(
  bash -c '
    set -euo pipefail
    PATH="$1"
    source "$2"
    run_status=0
    yes | vg_run_with_timeout 1 cat >/dev/null || run_status=$?
    printf "status=%s\n" "$run_status"
  ' -- "${NO_TIMEOUT_BIN}" "${REPO_DIR}/hooks/_lib/timeout.sh"
)"
timeout_unclosed_stdin_elapsed=$(( $(date +%s) - timeout_unclosed_stdin_started ))
assert_contains "${timeout_unclosed_stdin_out}" "status=124" "timeout fallback bounds unclosed pipeline stdin"
TOTAL=$((TOTAL + 1))
if [[ "${timeout_unclosed_stdin_elapsed}" -lt 3 ]]; then
  green "timeout fallback returns promptly for unclosed pipeline stdin"
  PASS=$((PASS + 1))
else
  red "timeout fallback returns promptly for unclosed pipeline stdin"
  FAIL=$((FAIL + 1))
fi

timeout_child_pid_file="${TMP_DIR}/timeout-child.pid"
timeout_tree_out="$(
  bash -c '
    set -euo pipefail
    PATH="$1"
    source "$2"
    pid_file="$3"
    run_status=0
    vg_run_with_timeout 1 bash -c '"'"'/bin/sleep 60 & echo $! > "$1"; wait'"'"' _ "$pid_file" || run_status=$?
    printf "status=%s\n" "$run_status"
  ' -- "${NO_TIMEOUT_BIN}" "${REPO_DIR}/hooks/_lib/timeout.sh" "${timeout_child_pid_file}"
)"
assert_contains "${timeout_tree_out}" "status=124" "timeout fallback returns 124 after killing slow command"
timeout_child_pid="$(cat "${timeout_child_pid_file}" 2>/dev/null || true)"
sleep 0.5
TOTAL=$((TOTAL + 1))
if [[ -n "${timeout_child_pid}" ]] && ps -p "${timeout_child_pid}" >/dev/null 2>&1; then
  kill "${timeout_child_pid}" 2>/dev/null || true
  sleep 0.1
  kill -KILL "${timeout_child_pid}" 2>/dev/null || true
  red "timeout fallback kills descendant processes"
  FAIL=$((FAIL + 1))
else
  green "timeout fallback kills descendant processes"
  PASS=$((PASS + 1))
fi

old_normalizer_runtime="${TMP_DIR}/old-normalizer-runtime"
cat > "${old_normalizer_runtime}" <<'SH'
#!/usr/bin/env bash
printf 'Unknown command: %s\n' "$1" >&2
exit 2
SH
chmod +x "${old_normalizer_runtime}"
old_runtime_patch_out="$(
  WRAPPER_DIR="${REPO_DIR}/hooks" VIBEGUARD_RUNTIME="${old_normalizer_runtime}" bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    source "$3"
    EVENT_NAME=PreToolUse
    codex_diag() { return 0; }
    codex_hook_status() { return 0; }
    codex_run_hook "vibeguard-pre-write-guard.sh" "$4" "$5"
  ' -- \
    "${REPO_DIR}/hooks/_lib/codex_diag.sh" \
    "${REPO_DIR}/hooks/_lib/codex_adapter.sh" \
    "${REPO_DIR}/hooks/_lib/codex_runner.sh" \
    "${TMP_FAKE_REPO_NO_PYTHON_PATCH}/hooks/vibeguard-pre-write-guard.sh" \
    "${no_python_patch_payload}"
)"
assert_contains "${old_runtime_patch_out}" '"permissionDecision":"deny"' "codex_run_hook fails closed when old runtime lacks apply_patch normalizer"
assert_contains "${old_runtime_patch_out}" 'Codex apply_patch normalizer failed' "old runtime missing normalizer is visible"
assert_not_contains "${old_runtime_patch_out}" 'apply_patch normalized without python' "old runtime missing normalizer does not use python fallback"

broken_no_python_patch_out="$(
  WRAPPER_DIR="${REPO_DIR}/hooks" PATH="${NO_PYTHON_BIN}:${PATH}" VIBEGUARD_RUNTIME="${BROKEN_RUNTIME}" bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    source "$3"
    EVENT_NAME=PreToolUse
    codex_diag() { return 0; }
    codex_hook_status() { return 0; }
    codex_run_hook "vibeguard-pre-write-guard.sh" "$4" "$5"
  ' -- \
    "${REPO_DIR}/hooks/_lib/codex_diag.sh" \
    "${REPO_DIR}/hooks/_lib/codex_adapter.sh" \
    "${REPO_DIR}/hooks/_lib/codex_runner.sh" \
    "${TMP_FAKE_REPO_NO_PYTHON_PATCH}/hooks/vibeguard-pre-write-guard.sh" \
    "${no_python_patch_payload}"
)"
assert_contains "${broken_no_python_patch_out}" '"permissionDecision":"deny"' "codex_run_hook fails closed when runtime normalizer fails"
assert_contains "${broken_no_python_patch_out}" 'Codex apply_patch normalizer failed' "broken apply_patch normalizer failure is visible"
assert_not_contains "${broken_no_python_patch_out}" 'apply_patch normalized without python' "broken apply_patch normalizer does not raw-pass to file hook"

status_parse_out="$(
  printf '{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"stop"}}}' \
    | "${VIBEGUARD_RUNTIME}" codex-status-from-output
)"
assert_contains "${status_parse_out}" $'block\t' "runtime maps nested Codex deny status"

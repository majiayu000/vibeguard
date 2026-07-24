header "Codex writer identity stays stable across wrapper parent PIDs (issue #673)"

SESSION_ID_TMP="${TMP_DIR}/session-identity"
mkdir -p "${SESSION_ID_TMP}"

cat > "${SESSION_ID_TMP}/wrapper-session-probe.sh" <<PROBE
#!/usr/bin/env bash
set -euo pipefail
source "${REPO_DIR}/hooks/_lib/wrapper_env.sh"
vg_wrapper_env_codex_session "\${1}"
vg_wrapper_env_export "codex"
printf 'session=%s source=%s\n' "\${VIBEGUARD_SESSION_ID:-}" "\${VIBEGUARD_SESSION_SOURCE:-}"
PROBE

# Each probe runs under a fresh short-lived intermediate bash so the wrapper
# sees a different parent PID per invocation, modeling the fragmenting native
# Codex process topology from issue #673.
run_session_probe() {
  local payload="$1"
  VIBEGUARD_LOG_DIR="${SESSION_ID_TMP}/logs" \
  VIBEGUARD_RUNTIME="${VIBEGUARD_RUNTIME}" \
    bash -c "bash '${SESSION_ID_TMP}/wrapper-session-probe.sh' '${payload//\'/}'"
}

_pre_payload='{"hook_event_name":"PreToolUse","session_id":"itest-thread-1","tool_name":"Edit","tool_input":{"file_path":"src/a.rs"}}'
_post_payload='{"hook_event_name":"PostToolUse","session_id":"itest-thread-1","tool_name":"Edit","tool_input":{"file_path":"src/a.rs"}}'
_other_payload='{"hook_event_name":"PostToolUse","session_id":"itest-thread-2","tool_name":"Edit","tool_input":{"file_path":"src/a.rs"}}'
_anonymous_payload='{"hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"src/a.rs"}}'

_pre_identity="$(run_session_probe "${_pre_payload}")"
_post_identity="$(run_session_probe "${_post_payload}")"
_other_identity="$(run_session_probe "${_other_payload}")"
_anonymous_identity="$(run_session_probe "${_anonymous_payload}")"

assert_contains "${_pre_identity}" "session=codex-thread-" "payload session_id derives a logical codex-thread identity"
assert_contains "${_pre_identity}" "source=codex-thread" "logical identity reports codex-thread session source"

TOTAL=$((TOTAL + 1))
if [[ "${_pre_identity}" == "${_post_identity}" ]]; then
  green "pre and post hooks of one logical thread share one writer identity across parent PIDs"
  PASS=$((PASS + 1))
else
  red "pre and post hooks of one logical thread share one writer identity across parent PIDs (pre=${_pre_identity} post=${_post_identity})"
  FAIL=$((FAIL + 1))
fi

TOTAL=$((TOTAL + 1))
if [[ "${_pre_identity}" != "${_other_identity}" ]]; then
  green "different logical threads keep distinct writer identities"
  PASS=$((PASS + 1))
else
  red "different logical threads keep distinct writer identities (both=${_pre_identity})"
  FAIL=$((FAIL + 1))
fi

assert_contains "${_anonymous_identity}" "session=" "missing payload session_id still resolves a fallback session"
assert_not_contains "${_anonymous_identity}" "source=codex-thread" "missing payload session_id does not claim logical identity"

assert_contains "$(cat "${REPO_DIR}/hooks/run-hook-codex.sh")" 'vg_wrapper_env_codex_session "${INPUT}"; vg_wrapper_env_export "codex"' "run-hook-codex.sh derives logical identity before wrapper env export"

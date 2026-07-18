#!/usr/bin/env bash
# Runtime policy enforcement for invalid .vibeguard.json and malformed ~/.vibeguard/config.json.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
hook_test_init

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR" "$VIBEGUARD_LOG_DIR"' EXIT
RUNTIME_BIN="${REPO_DIR}/vibeguard-runtime/target/debug/vibeguard-runtime"
cargo build --manifest-path "${REPO_DIR}/vibeguard-runtime/Cargo.toml" >/dev/null

make_home() {
  local home_dir="$1"
  mkdir -p "${home_dir}/.vibeguard"
  printf '%s' "${REPO_DIR}" > "${home_dir}/.vibeguard/repo-path"
  printf '%s\n' "dev-linked-repo" > "${home_dir}/.vibeguard/execution-mode"
  hook_test_install_runtime_stub "${home_dir}"
}

make_project() {
  local project_dir="$1" config_body="$2"
  mkdir -p "${project_dir}"
  printf '%s\n' "${config_body}" > "${project_dir}/.vibeguard.json"
}

run_claude_wrapper() {
  local home_dir="$1" project_dir="$2" hook_name="$3" input="$4"
  cd "${project_dir}"
  printf '%s' "${input}" \
    | HOME="${home_dir}" VIBEGUARD_LOG_DIR="${home_dir}/.vibeguard" \
      VIBEGUARD_POLICY_RUNTIME="${RUNTIME_BIN}" \
      bash "${REPO_DIR}/hooks/run-hook.sh" "${hook_name}"
}

run_codex_wrapper() {
  local home_dir="$1" project_dir="$2" hook_name="$3" input="$4"
  cd "${project_dir}"
  printf '%s' "${input}" \
    | HOME="${home_dir}" VIBEGUARD_LOG_DIR="${home_dir}/.vibeguard" \
      VIBEGUARD_POLICY_RUNTIME="${RUNTIME_BIN}" \
      bash "${REPO_DIR}/hooks/run-hook-codex.sh" "${hook_name}"
}

pretool_block_input='{"tool_input":{"command":"git push --force"}}'
codex_pretool_input='{"hook_event_name":"PreToolUse","tool_input":{"command":"git push --force"}}'

header "runtime policy — invalid project config"
bad_project_home="${WORK_DIR}/home-bad-project"
bad_project="${WORK_DIR}/project-bad"
make_home "${bad_project_home}"
make_project "${bad_project}" '{"disabled_hooks":["missing-hook"]}'

set +e
bad_project_claude_out="$(run_claude_wrapper "${bad_project_home}" "${bad_project}" pre-bash-guard.sh "${pretool_block_input}" 2>&1)"
bad_project_claude_status=$?
set -e
TOTAL=$((TOTAL + 1))
if [[ "${bad_project_claude_status}" -eq 0 ]]; then
  green "Claude wrapper exits cleanly after invalid .vibeguard.json block"
  PASS=$((PASS + 1))
else
  red "Claude wrapper exits cleanly after invalid .vibeguard.json block"
  FAIL=$((FAIL + 1))
fi
assert_contains "${bad_project_claude_out}" '"decision":"block"' "Claude wrapper blocks invalid .vibeguard.json"
assert_contains "${bad_project_claude_out}" "VibeGuard project config invalid" "Claude wrapper explains invalid .vibeguard.json"

set +e
bad_project_codex_out="$(run_codex_wrapper "${bad_project_home}" "${bad_project}" vibeguard-pre-bash-guard.sh "${codex_pretool_input}" 2>&1)"
bad_project_codex_status=$?
set -e
TOTAL=$((TOTAL + 1))
if [[ "${bad_project_codex_status}" -eq 0 ]]; then
  green "Codex wrapper exits cleanly after emitting policy denial"
  PASS=$((PASS + 1))
else
  red "Codex wrapper exits cleanly after emitting policy denial"
  FAIL=$((FAIL + 1))
fi
assert_contains "${bad_project_codex_out}" '"permissionDecision": "deny"' "Codex wrapper denies invalid .vibeguard.json"
assert_contains "${bad_project_codex_out}" "VibeGuard project config invalid" "Codex wrapper explains invalid .vibeguard.json"

header "runtime policy — malformed user runtime config"
bad_user_home="${WORK_DIR}/home-bad-user"
bad_user_project="${WORK_DIR}/project-bad-user"
make_home "${bad_user_home}"
make_project "${bad_user_project}" '{}'
bad_user_config="${bad_user_home}/.vibeguard/config.json"
printf '{"write_mode":' > "${bad_user_config}"

set +e
bad_user_claude_out="$(
  cd "${bad_user_project}" && printf '%s' "${pretool_block_input}" \
    | HOME="${bad_user_home}" VIBEGUARD_LOG_DIR="${bad_user_home}/.vibeguard" \
      VIBEGUARD_POLICY_RUNTIME="${RUNTIME_BIN}" \
      bash "${REPO_DIR}/hooks/run-hook.sh" pre-bash-guard.sh 2>&1
)"
bad_user_claude_status=$?
set -e
TOTAL=$((TOTAL + 1))
if [[ "${bad_user_claude_status}" -eq 0 ]]; then
  green "Claude wrapper exits cleanly after malformed runtime config block"
  PASS=$((PASS + 1))
else
  red "Claude wrapper exits cleanly after malformed runtime config block"
  FAIL=$((FAIL + 1))
fi
assert_contains "${bad_user_claude_out}" '"decision":"block"' "Claude wrapper blocks malformed runtime config"
assert_contains "${bad_user_claude_out}" "VibeGuard runtime config invalid JSON" "Claude wrapper explains malformed runtime config"

set +e
bad_user_stop_out="$(
  cd "${bad_user_project}" && printf '{"hook_event_name":"Stop"}' \
    | HOME="${bad_user_home}" VIBEGUARD_LOG_DIR="${bad_user_home}/.vibeguard" \
      VIBEGUARD_POLICY_RUNTIME="${RUNTIME_BIN}" \
      bash "${REPO_DIR}/hooks/run-hook.sh" stop-guard.sh 2>&1
)"
bad_user_stop_status=$?
set -e
TOTAL=$((TOTAL + 1))
if [[ "${bad_user_stop_status}" -eq 0 ]]; then
  green "Claude Stop hook exits cleanly on malformed runtime config"
  PASS=$((PASS + 1))
else
  red "Claude Stop hook exits cleanly on malformed runtime config"
  FAIL=$((FAIL + 1))
fi
assert_not_contains "${bad_user_stop_out}" '"decision":"block"' "Claude Stop hook does not block on malformed runtime config"
assert_contains "${bad_user_stop_out}" "VibeGuard runtime config invalid JSON" "Claude Stop hook keeps malformed runtime config visible"

set +e
bad_user_session_out="$(
  cd "${bad_user_project}" && printf '{"hook_event_name":"SessionStart"}' \
    | HOME="${bad_user_home}" VIBEGUARD_LOG_DIR="${bad_user_home}/.vibeguard" \
      VIBEGUARD_POLICY_RUNTIME="${RUNTIME_BIN}" \
      bash "${REPO_DIR}/hooks/run-hook.sh" count_active_constraints.sh 2>&1
)"
bad_user_session_status=$?
set -e
TOTAL=$((TOTAL + 1))
if [[ "${bad_user_session_status}" -eq 0 ]]; then
  green "Claude SessionStart hook exits cleanly on malformed runtime config"
  PASS=$((PASS + 1))
else
  red "Claude SessionStart hook exits cleanly on malformed runtime config"
  FAIL=$((FAIL + 1))
fi
assert_not_contains "${bad_user_session_out}" '"decision":"block"' "Claude SessionStart hook does not block on malformed runtime config"
assert_contains "${bad_user_session_out}" "VibeGuard runtime config invalid JSON" "Claude SessionStart hook keeps malformed runtime config visible"

set +e
bad_user_codex_out="$(
  cd "${bad_user_project}" && printf '%s' "${codex_pretool_input}" \
    | HOME="${bad_user_home}" VIBEGUARD_LOG_DIR="${bad_user_home}/.vibeguard" \
      VIBEGUARD_POLICY_RUNTIME="${RUNTIME_BIN}" \
      bash "${REPO_DIR}/hooks/run-hook-codex.sh" vibeguard-pre-bash-guard.sh 2>&1
)"
bad_user_codex_status=$?
set -e
TOTAL=$((TOTAL + 1))
if [[ "${bad_user_codex_status}" -eq 0 ]]; then
  green "Codex wrapper exits cleanly after malformed config denial"
  PASS=$((PASS + 1))
else
  red "Codex wrapper exits cleanly after malformed config denial"
  FAIL=$((FAIL + 1))
fi
assert_contains "${bad_user_codex_out}" '"permissionDecision": "deny"' "Codex wrapper denies malformed runtime config"
assert_contains "${bad_user_codex_out}" "VibeGuard runtime config invalid JSON" "Codex wrapper explains malformed runtime config"
assert_contains "$(cat "${bad_user_home}/.vibeguard/policy.jsonl")" "config_parse_error" "runtime policy emits config_parse_error telemetry"

header "runtime policy — no Python policy helpers"
assert_not_contains "$(sed -n '1,240p' "${REPO_DIR}/hooks/_lib/policy.sh")" "python3" "policy helper no longer shells out to python3"

hook_test_finish

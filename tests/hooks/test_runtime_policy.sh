#!/usr/bin/env bash
# Runtime policy enforcement for .vibeguard.json and ~/.vibeguard/config.json.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
hook_test_init

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR" "$VIBEGUARD_LOG_DIR"' EXIT

make_home() {
  local home_dir="$1"
  mkdir -p "${home_dir}/.vibeguard"
  printf '%s' "${REPO_DIR}" > "${home_dir}/.vibeguard/repo-path"
}

make_project() {
  local project_dir="$1" config_body="$2"
  mkdir -p "${project_dir}"
  printf '%s\n' "${config_body}" > "${project_dir}/.vibeguard.json"
}

assert_empty_success() {
  local status="$1" output="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "${status}" -eq 0 && -z "${output}" ]]; then
    green "${desc}"
    PASS=$((PASS + 1))
  else
    red "${desc} (status=${status}, output=${output})"
    FAIL=$((FAIL + 1))
  fi
}

run_claude_wrapper() {
  local home_dir="$1" project_dir="$2" hook_name="$3" input="$4"
  cd "${project_dir}"
  printf '%s' "${input}" \
    | HOME="${home_dir}" VIBEGUARD_LOG_DIR="${home_dir}/.vibeguard" \
      bash "${REPO_DIR}/hooks/run-hook.sh" "${hook_name}"
}

run_codex_wrapper() {
  local home_dir="$1" project_dir="$2" hook_name="$3" input="$4"
  cd "${project_dir}"
  printf '%s' "${input}" \
    | HOME="${home_dir}" VIBEGUARD_LOG_DIR="${home_dir}/.vibeguard" \
      bash "${REPO_DIR}/hooks/run-hook-codex.sh" "${hook_name}"
}

pretool_block_input='{"tool_input":{"command":"git push --force"}}'
codex_pretool_input='{"hook_event_name":"PreToolUse","tool_input":{"command":"git push --force"}}'

header "runtime policy — disabled hooks"
disabled_home="${WORK_DIR}/home-disabled"
disabled_project="${WORK_DIR}/project-disabled"
make_home "${disabled_home}"
make_project "${disabled_project}" '{"disabled_hooks":["pre-bash-guard"]}'

set +e
disabled_claude_out="$(run_claude_wrapper "${disabled_home}" "${disabled_project}" pre-bash-guard.sh "${pretool_block_input}" 2>&1)"
disabled_claude_status=$?
set -e
assert_empty_success "${disabled_claude_status}" "${disabled_claude_out}" "Claude wrapper honors disabled_hooks before executing hook"

set +e
disabled_codex_out="$(run_codex_wrapper "${disabled_home}" "${disabled_project}" vibeguard-pre-bash-guard.sh "${codex_pretool_input}" 2>&1)"
disabled_codex_status=$?
set -e
assert_empty_success "${disabled_codex_status}" "${disabled_codex_out}" "Codex wrapper honors disabled_hooks before executing hook"

assert_contains "$(cat "${disabled_home}/.vibeguard/policy.jsonl")" "policy_skip" "runtime policy emits policy_skip telemetry"

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
if [[ "${bad_project_claude_status}" -ne 0 ]]; then
  green "Claude wrapper fails loudly on invalid .vibeguard.json"
  PASS=$((PASS + 1))
else
  red "Claude wrapper fails loudly on invalid .vibeguard.json"
  FAIL=$((FAIL + 1))
fi
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
bad_user_config="${WORK_DIR}/bad-config.json"
make_home "${bad_user_home}"
make_project "${bad_user_project}" '{}'
printf '{"write_mode":' > "${bad_user_config}"

set +e
bad_user_claude_out="$(
  cd "${bad_user_project}" && printf '%s' "${pretool_block_input}" \
    | HOME="${bad_user_home}" VIBEGUARD_LOG_DIR="${bad_user_home}/.vibeguard" \
      VIBEGUARD_CONFIG_FILE="${bad_user_config}" \
      bash "${REPO_DIR}/hooks/run-hook.sh" pre-bash-guard.sh 2>&1
)"
bad_user_claude_status=$?
set -e
TOTAL=$((TOTAL + 1))
if [[ "${bad_user_claude_status}" -ne 0 ]]; then
  green "Claude wrapper fails loudly on malformed runtime config"
  PASS=$((PASS + 1))
else
  red "Claude wrapper fails loudly on malformed runtime config"
  FAIL=$((FAIL + 1))
fi
assert_contains "${bad_user_claude_out}" "VibeGuard runtime config invalid JSON" "Claude wrapper explains malformed runtime config"

set +e
bad_user_codex_out="$(
  cd "${bad_user_project}" && printf '%s' "${codex_pretool_input}" \
    | HOME="${bad_user_home}" VIBEGUARD_LOG_DIR="${bad_user_home}/.vibeguard" \
      VIBEGUARD_CONFIG_FILE="${bad_user_config}" \
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

hook_test_finish

#!/usr/bin/env bash
# Structured runtime-policy-check JSON protocol and explicit cwd handoff.
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
  hook_test_install_runtime_stub "${home_dir}"
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

header "runtime policy — structured JSON parsing"
json_policy_runtime="${WORK_DIR}/json-policy-runtime"
cat > "${json_policy_runtime}" <<'SH'
#!/usr/bin/env bash
command="${1:-}"
shift || true
case "${command}" in
  runtime-policy-supports)
    exit 0
    ;;
  runtime-policy-check)
    hook_name="${*: -1}"
    printf '{"decision":"run","enforcement":"%s","hook":"%s","profile":"core","config_path":null,"reason":"compat text says enforcement=warn"}\n' "${VG_STUB_ENFORCEMENT:-block}" "${hook_name}"
    ;;
  json-field|runtime-policy-downgrade-output|runtime-policy-codex-error|runtime-policy-diag)
    exec "${REAL_RUNTIME:?}" "${command}" "$@"
    ;;
  *)
    exit 2
    ;;
esac
SH
chmod +x "${json_policy_runtime}"

structured_block_out="$(
  WRAPPER_DIR="${REPO_DIR}/hooks" \
  VIBEGUARD_POLICY_RUNTIME="${json_policy_runtime}" \
  REAL_RUNTIME="${RUNTIME_BIN}" \
  VG_STUB_ENFORCEMENT="block" \
  bash -c '
    source hooks/_lib/policy.sh
    vg_policy_check_hook pre-bash-guard.sh
    status=$?
    printf "status=%s enforcement=%s kind=%s reason=%s\n" "$status" "$VG_POLICY_ENFORCEMENT" "$VG_POLICY_KIND" "$VG_POLICY_REASON"
  '
)"
assert_contains "${structured_block_out}" "status=0" "policy helper accepts structured allow JSON"
assert_contains "${structured_block_out}" "enforcement=block" "policy helper ignores warn-looking compatibility reason when enforcement is block"
assert_not_contains "${structured_block_out}" "kind=policy_warn" "policy helper does not infer warn mode from reason substring"

structured_warn_out="$(
  WRAPPER_DIR="${REPO_DIR}/hooks" \
  VIBEGUARD_POLICY_RUNTIME="${json_policy_runtime}" \
  REAL_RUNTIME="${RUNTIME_BIN}" \
  VG_STUB_ENFORCEMENT="warn" \
  bash -c '
    source hooks/_lib/policy.sh
    vg_policy_check_hook pre-bash-guard.sh
    status=$?
    printf "status=%s enforcement=%s kind=%s reason=%s\n" "$status" "$VG_POLICY_ENFORCEMENT" "$VG_POLICY_KIND" "$VG_POLICY_REASON"
  '
)"
assert_contains "${structured_warn_out}" "status=0" "policy helper accepts structured warn JSON"
assert_contains "${structured_warn_out}" "enforcement=warn" "policy helper enables warn mode from JSON enforcement"
assert_contains "${structured_warn_out}" "kind=policy_warn" "policy helper records warn kind from JSON enforcement"

header "runtime policy — explicit wrapper cwd"
payload_cwd_home="${WORK_DIR}/home-payload-cwd"
payload_cwd_project="${WORK_DIR}/project-payload-cwd"
payload_cwd_process="${WORK_DIR}/process-payload-cwd"
make_home "${payload_cwd_home}"
make_project "${payload_cwd_project}" '{"disabled_hooks":["pre-bash-guard"]}'
mkdir -p "${payload_cwd_process}"

set +e
payload_cwd_claude_out="$(
  cd "${payload_cwd_process}" && printf '{"cwd":"%s","tool_input":{"command":"git push --force"}}' "${payload_cwd_project}" \
    | HOME="${payload_cwd_home}" VIBEGUARD_LOG_DIR="${payload_cwd_home}/.vibeguard" \
      VIBEGUARD_POLICY_RUNTIME="${RUNTIME_BIN}" \
      bash "${REPO_DIR}/hooks/run-hook.sh" pre-bash-guard.sh 2>&1
)"
payload_cwd_claude_status=$?
set -e
assert_empty_success "${payload_cwd_claude_status}" "${payload_cwd_claude_out}" "Claude wrapper uses payload cwd for runtime policy"

set +e
payload_cwd_codex_out="$(
  cd "${payload_cwd_process}" && printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_input":{"command":"git push --force"}}' "${payload_cwd_project}" \
    | HOME="${payload_cwd_home}" VIBEGUARD_LOG_DIR="${payload_cwd_home}/.vibeguard" \
      VIBEGUARD_POLICY_RUNTIME="${RUNTIME_BIN}" \
      bash "${REPO_DIR}/hooks/run-hook-codex.sh" vibeguard-pre-bash-guard.sh 2>&1
)"
payload_cwd_codex_status=$?
set -e
assert_empty_success "${payload_cwd_codex_status}" "${payload_cwd_codex_out}" "Codex wrapper uses payload cwd for runtime policy"

hook_test_finish

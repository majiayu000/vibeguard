#!/usr/bin/env bash
# Runtime policy enforcement for .vibeguard.json and ~/.vibeguard/config.json.
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

probe_large_claude_stdin() {
  local home_dir="$1" project_dir="$2" hook_name="$3"
  node - "${home_dir}" "${project_dir}" "${hook_name}" "${REPO_DIR}" <<'NODE'
const { spawn } = require('node:child_process');

const [homeDir, projectDir, hookName, repoDir] = process.argv.slice(2);
const child = spawn('bash', [`${repoDir}/hooks/run-hook.sh`, hookName], {
  cwd: projectDir,
  env: {
    ...process.env,
    HOME: homeDir,
    VIBEGUARD_LOG_DIR: `${homeDir}/.vibeguard`,
    VIBEGUARD_POLICY_RUNTIME: `${repoDir}/vibeguard-runtime/target/debug/vibeguard-runtime`,
  },
  stdio: ['pipe', 'pipe', 'pipe'],
});

let stdinError = '';
let stdout = '';
let stderr = '';

child.stdout.on('data', (data) => { stdout += data; });
child.stderr.on('data', (data) => { stderr += data; });
child.stdin.on('error', (error) => { stdinError = error.code || String(error); });

const payload = JSON.stringify({
  tool_input: {
    command: 'git push --force',
    content: 'x'.repeat(8 * 1024 * 1024),
  },
});

child.stdin.write(payload, (error) => {
  if (error) stdinError = error.code || String(error);
});
child.stdin.end();

child.on('close', (code, signal) => {
  console.log(JSON.stringify({
    code,
    signal,
    stdinError,
    stdout: stdout.slice(0, 120),
    stderr: stderr.slice(0, 120),
  }));
});
NODE
}

pretool_block_input='{"tool_input":{"command":"git push --force"}}'
codex_pretool_input='{"hook_event_name":"PreToolUse","tool_input":{"command":"git push --force"}}'
pretool_danger_input='{"tool_input":{"command":"git clean -f"}}'
codex_pretool_danger_input='{"hook_event_name":"PreToolUse","tool_input":{"command":"git clean -f"}}'

header "runtime policy — runtime resolver"
explicit_runtime="${WORK_DIR}/explicit-runtime"
cat > "${explicit_runtime}" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  runtime-policy-check)
    exit 0
    ;;
  runtime-policy-downgrade-output)
    printf '{"decision":"warn","reason":"probe"}\n'
    ;;
  runtime-policy-codex-error)
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"probe"}}\n'
    ;;
  runtime-policy-diag)
    printf '{"kind":"policy_error"}\n' >>"${2:?}"
    ;;
  *)
    exit 2
    ;;
esac
SH
chmod +x "${explicit_runtime}"
resolver_out="$(
  WRAPPER_DIR="${REPO_DIR}/hooks" VIBEGUARD_POLICY_RUNTIME="${explicit_runtime}" bash -c '
    source hooks/_lib/policy.sh
    vg_policy_runtime_path
  '
)"
assert_contains "${resolver_out}" "${explicit_runtime}" "runtime policy resolver honors explicit VIBEGUARD_POLICY_RUNTIME before checkout binaries"

optimized_runtime="${WORK_DIR}/optimized-runtime"
optimized_probe_log="${WORK_DIR}/optimized-runtime.log"
cat > "${optimized_runtime}" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  runtime-policy-supports)
    printf 'supports\n' >>"${OPTIMIZED_PROBE_LOG:?}"
    exit 0
    ;;
  runtime-policy-check|runtime-policy-downgrade-output|runtime-policy-codex-error|runtime-policy-diag)
    printf 'unexpected:%s\n' "${1:-}" >>"${OPTIMIZED_PROBE_LOG:?}"
    exit 70
    ;;
  *)
    exit 2
    ;;
esac
SH
chmod +x "${optimized_runtime}"
resolver_out="$(
  WRAPPER_DIR="${REPO_DIR}/hooks" \
  VIBEGUARD_POLICY_RUNTIME="${optimized_runtime}" \
  OPTIMIZED_PROBE_LOG="${optimized_probe_log}" \
  bash -c '
    source hooks/_lib/policy.sh
    vg_policy_runtime_path
  '
)"
assert_contains "${resolver_out}" "${optimized_runtime}" "runtime policy resolver accepts batched support probe"
assert_contains "$(cat "${optimized_probe_log}")" "supports" "runtime policy resolver calls batched support probe"
assert_not_contains "$(cat "${optimized_probe_log}")" "unexpected:" "runtime policy resolver skips legacy semantic probes when batched probe passes"

resolver_home="${WORK_DIR}/home-resolver"
mkdir -p "${resolver_home}/.vibeguard/installed/bin"
stale_installed_runtime="${resolver_home}/.vibeguard/installed/bin/vibeguard-runtime"
printf '#!/usr/bin/env bash\necho stale-installed-runtime >&2\nexit 2\n' > "${stale_installed_runtime}"
chmod +x "${stale_installed_runtime}"
resolver_out="$(
  WRAPPER_DIR="${REPO_DIR}/hooks" \
  HOME="${resolver_home}" \
  VIBEGUARD_RUNTIME="${explicit_runtime}" \
  bash -c '
    source hooks/_lib/policy.sh
    vg_policy_runtime_path
  '
)"
assert_contains "${resolver_out}" "${explicit_runtime}" "runtime policy resolver honors VIBEGUARD_RUNTIME before installed binaries"

installed_wrapper_home="${WORK_DIR}/home-installed-wrapper"
mkdir -p "${installed_wrapper_home}/.vibeguard/installed/bin"
cp "${explicit_runtime}" "${installed_wrapper_home}/.vibeguard/installed/bin/vibeguard-runtime"
resolver_out="$(
  WRAPPER_DIR="${installed_wrapper_home}/.vibeguard" \
  HOME="${installed_wrapper_home}" \
  env -u VIBEGUARD_POLICY_RUNTIME -u VIBEGUARD_RUNTIME bash -c '
    source hooks/_lib/policy.sh
    vg_policy_runtime_path
  '
)"
assert_contains "${resolver_out}" "${installed_wrapper_home}/.vibeguard/installed/bin/vibeguard-runtime" "runtime policy resolver prefers installed runtime for installed wrapper"

partial_runtime="${WORK_DIR}/partial-runtime"
cat > "${partial_runtime}" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "runtime-policy-check" ]]; then
  exit 0
fi
echo "missing helper: ${1:-}" >&2
exit 2
SH
chmod +x "${partial_runtime}"
resolver_out="$(
  WRAPPER_DIR="${REPO_DIR}/hooks" \
  VIBEGUARD_POLICY_RUNTIME="${partial_runtime}" \
  VIBEGUARD_RUNTIME="${RUNTIME_BIN}" \
  bash -c '
    source hooks/_lib/policy.sh
    vg_policy_runtime_path
  '
)"
assert_not_contains "${resolver_out}" "${partial_runtime}" "runtime policy resolver rejects runtimes missing helper commands"
assert_contains "${resolver_out}" "${RUNTIME_BIN}" "runtime policy resolver falls through to helper-capable runtime"

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

disabled_large_stdin_out="$(probe_large_claude_stdin "${disabled_home}" "${disabled_project}" pre-bash-guard.sh)"
assert_contains "${disabled_large_stdin_out}" '"code":0' "Claude wrapper disabled hook exits cleanly after large stdin"
assert_contains "${disabled_large_stdin_out}" '"stdinError":""' "Claude wrapper drains large stdin before disabled hook skip"
assert_contains "${disabled_large_stdin_out}" '"stdout":""' "Claude wrapper disabled hook produces no stdout after large stdin"
assert_contains "${disabled_large_stdin_out}" '"stderr":""' "Claude wrapper disabled hook produces no stderr after large stdin"

assert_contains "$(cat "${disabled_home}/.vibeguard/policy.jsonl")" "policy_skip" "runtime policy emits policy_skip telemetry"

header "runtime policy — warn enforcement"
warn_home="${WORK_DIR}/home-warn"
warn_project="${WORK_DIR}/project-warn"
make_home "${warn_home}"
make_project "${warn_project}" '{"enforcement":"warn"}'

warn_claude_out="$(run_claude_wrapper "${warn_home}" "${warn_project}" pre-bash-guard.sh "${pretool_danger_input}" 2>&1)"
assert_contains "${warn_claude_out}" '"decision": "warn"' "Claude wrapper downgrades block output in warn mode"
assert_not_contains "${warn_claude_out}" '"decision": "block"' "Claude wrapper does not hard-block in warn mode"

warn_codex_out="$(run_codex_wrapper "${warn_home}" "${warn_project}" vibeguard-pre-bash-guard.sh "${codex_pretool_danger_input}" 2>&1)"
assert_contains "${warn_codex_out}" "systemMessage" "Codex wrapper emits advisory in warn mode"
assert_not_contains "${warn_codex_out}" '"permissionDecision": "deny"' "Codex wrapper does not deny in warn mode"
assert_contains "$(cat "${warn_home}/.vibeguard/projects/"*/events.jsonl)" '"decision": "warn"' "warn mode records downgraded warning telemetry"

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
      VIBEGUARD_POLICY_RUNTIME="${RUNTIME_BIN}" \
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
      VIBEGUARD_POLICY_RUNTIME="${RUNTIME_BIN}" \
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

header "runtime policy — no Python policy helpers"
assert_not_contains "$(sed -n '1,240p' "${REPO_DIR}/hooks/_lib/policy.sh")" "python3" "policy helper no longer shells out to python3"

hook_test_finish

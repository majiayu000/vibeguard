#!/usr/bin/env bash

RUNTIME_POLICY_TEST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${RUNTIME_POLICY_TEST_LIB_DIR}/hook_test_lib.sh"
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

make_installed_snapshot_home() {
  local home_dir="$1" installed_version="$2"
  mkdir -p "${home_dir}/.vibeguard/installed/hooks"
  printf '%s' "${REPO_DIR}" > "${home_dir}/.vibeguard/repo-path"
  printf '%s\n' "${installed_version}" > "${home_dir}/.vibeguard/installed/version"
  hook_test_install_runtime_stub "${home_dir}"
  cat > "${home_dir}/.vibeguard/installed/hooks/pre-bash-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
exit 0
SH
  chmod +x "${home_dir}/.vibeguard/installed/hooks/pre-bash-guard.sh"
}

run_installed_claude_wrapper() {
  local home_dir="$1" session_id="$2" input="$3"
  printf '%s' "${input}" \
    | HOME="${home_dir}" VIBEGUARD_LOG_DIR="${home_dir}/.vibeguard" \
      VIBEGUARD_SESSION_ID="${session_id}" \
      VIBEGUARD_POLICY_RUNTIME="${RUNTIME_BIN}" \
      bash "${REPO_DIR}/hooks/run-hook.sh" pre-bash-guard.sh
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

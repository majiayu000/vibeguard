header "run-hook-codex handles large payloads without env overflow"
TMP_HOME_LARGE_PAYLOAD="${TMP_DIR}/home-large-payload"
TMP_FAKE_REPO_LARGE_PAYLOAD="${TMP_DIR}/fake-repo-large-payload"
LARGE_PAYLOAD_DIAG="${TMP_DIR}/large-payload-codex-wrapper.jsonl"
mkdir -p "${TMP_HOME_LARGE_PAYLOAD}/.vibeguard" "${TMP_FAKE_REPO_LARGE_PAYLOAD}/hooks"
printf '%s' "${TMP_FAKE_REPO_LARGE_PAYLOAD}" > "${TMP_HOME_LARGE_PAYLOAD}/.vibeguard/repo-path"

cat > "${TMP_FAKE_REPO_LARGE_PAYLOAD}/hooks/vibeguard-post-build-check.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
exit 0
HOOK
chmod +x "${TMP_FAKE_REPO_LARGE_PAYLOAD}/hooks/vibeguard-post-build-check.sh"

large_payload_probe="$(
  node - "${REPO_DIR}" "${TMP_HOME_LARGE_PAYLOAD}" "${LARGE_PAYLOAD_DIAG}" <<'NODE'
const { spawn } = require('node:child_process');

const [repoDir, homeDir, diagFile] = process.argv.slice(2);
const child = spawn('bash', [`${repoDir}/hooks/run-hook-codex.sh`, 'vibeguard-post-build-check.sh'], {
  cwd: repoDir,
  env: {
    ...process.env,
    HOME: homeDir,
    VIBEGUARD_CODEX_DIAG_FILE: diagFile,
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
  hook_event_name: 'PostToolUse',
  tool_name: 'Bash',
  tool_input: {
    command: 'x'.repeat(2 * 1024 * 1024),
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
    stderr: stderr.slice(0, 200),
  }));
});
NODE
)"
assert_contains "${large_payload_probe}" '"code":0' "large Codex payload exits cleanly"
assert_contains "${large_payload_probe}" '"stdinError":""' "large Codex payload is accepted over stdin"
assert_not_contains "${large_payload_probe}" "Argument list too long" "large Codex payload avoids execve env overflow"
assert_contains "$(cat "${LARGE_PAYLOAD_DIAG}")" '"status": "pass"' "large Codex payload records pass status"

header "run-hook-codex handles large hook output without env overflow"
TMP_HOME_LARGE_OUTPUT="${TMP_DIR}/home-large-output"
TMP_FAKE_REPO_LARGE_OUTPUT="${TMP_DIR}/fake-repo-large-output"
LARGE_OUTPUT_DIAG="${TMP_DIR}/large-output-codex-wrapper.jsonl"
mkdir -p "${TMP_HOME_LARGE_OUTPUT}/.vibeguard" "${TMP_FAKE_REPO_LARGE_OUTPUT}/hooks"
printf '%s' "${TMP_FAKE_REPO_LARGE_OUTPUT}" > "${TMP_HOME_LARGE_OUTPUT}/.vibeguard/repo-path"

cat > "${TMP_FAKE_REPO_LARGE_OUTPUT}/hooks/vibeguard-post-build-check.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
python3 - <<'PY'
import json

print(json.dumps({
    "decision": "block",
    "reason": "large-hook-output-sentinel:" + ("x" * (2 * 1024 * 1024)),
}))
PY
HOOK
chmod +x "${TMP_FAKE_REPO_LARGE_OUTPUT}/hooks/vibeguard-post-build-check.sh"

large_output_probe="$(
  node - "${REPO_DIR}" "${TMP_HOME_LARGE_OUTPUT}" "${LARGE_OUTPUT_DIAG}" <<'NODE'
const { spawn } = require('node:child_process');

const [repoDir, homeDir, diagFile] = process.argv.slice(2);
const child = spawn('bash', [`${repoDir}/hooks/run-hook-codex.sh`, 'vibeguard-post-build-check.sh'], {
  cwd: repoDir,
  env: {
    ...process.env,
    HOME: homeDir,
    VIBEGUARD_CODEX_DIAG_FILE: diagFile,
  },
  stdio: ['pipe', 'pipe', 'pipe'],
});

let stdout = '';
let stderr = '';

child.stdout.on('data', (data) => { stdout += data; });
child.stderr.on('data', (data) => { stderr += data; });

child.stdin.end(JSON.stringify({
  hook_event_name: 'PostToolUse',
  tool_name: 'Bash',
  tool_input: {
    command: 'cargo check',
  },
}));

child.on('close', (code, signal) => {
  console.log(JSON.stringify({
    code,
    signal,
    stdoutHasBlock: stdout.includes('"decision": "block"'),
    stdoutHasSentinel: stdout.includes('large-hook-output-sentinel'),
    stderr: stderr.slice(0, 200),
  }));
});
NODE
)"
assert_contains "${large_output_probe}" '"code":0' "large Codex hook output exits cleanly"
assert_contains "${large_output_probe}" '"stdoutHasBlock":true' "large Codex hook output is adapted"
assert_contains "${large_output_probe}" '"stdoutHasSentinel":true' "large Codex hook output preserves the reason"
assert_not_contains "${large_output_probe}" "Argument list too long" "large Codex hook output avoids execve env overflow"
assert_contains "$(cat "${LARGE_OUTPUT_DIAG}")" '"status": "block"' "large Codex hook output records block status"

header "run-hook-codex adapts posttool block output"
TMP_HOME_POSTTOOL="${TMP_DIR}/home-posttool"
TMP_FAKE_REPO_POSTTOOL="${TMP_DIR}/fake-repo-posttool"
POSTTOOL_DIAG_FILE="${TMP_DIR}/posttool-codex-wrapper.jsonl"
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
    | HOME="${TMP_HOME_POSTTOOL}" VIBEGUARD_CODEX_DIAG_FILE="${POSTTOOL_DIAG_FILE}" bash "${REPO_DIR}/hooks/run-hook-codex.sh" vibeguard-post-build-check.sh
)"
assert_contains "${posttool_out}" '"decision": "block"' "run-hook-codex preserves posttool block decisions"
assert_contains "${posttool_out}" '"additionalContext": "build failed"' "run-hook-codex maps posttool reason to additionalContext"
assert_codex_posttool_output_contract "${posttool_out}" "posttool block matches Codex PostToolUse output contract"
assert_contains "$(cat "${POSTTOOL_DIAG_FILE}")" '"status": "running"' "run-hook-codex writes running status before posttool output"
assert_contains "$(cat "${POSTTOOL_DIAG_FILE}")" '"status": "block"' "run-hook-codex writes final status for posttool output"


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

header "run-hook-codex surfaces unsupported command rewrite"
TMP_HOME="${TMP_DIR}/home"
TMP_FAKE_REPO="${TMP_DIR}/fake-repo"
mkdir -p "${TMP_HOME}/.vibeguard" "${TMP_FAKE_REPO}/hooks"
printf '%s' "${TMP_FAKE_REPO}" > "${TMP_HOME}/.vibeguard/repo-path"

cat > "${TMP_FAKE_REPO}/hooks/vibeguard-pre-bash-guard.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
python3 - <<'PY'
import json
print(json.dumps({"decision": "allow", "updatedInput": {"command": "pnpm install"}}))
PY
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

header "app-server adapter propagates explicit session context and feedback"
adapter_json="$(python3 - "${REPO_DIR}" "${TMP_DIR}" <<'PYCODE'
import json
import importlib.util
import pathlib
import subprocess
import sys

repo_dir = pathlib.Path(sys.argv[1])
tmp_root = pathlib.Path(sys.argv[2])
module_path = repo_dir / "scripts" / "codex" / "app_server_wrapper.py"
spec = importlib.util.spec_from_file_location("vibeguard_app_server_wrapper", module_path)
module = importlib.util.module_from_spec(spec)
assert spec is not None and spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
SessionState = module.SessionState
VibeGuardGateStrategy = module.VibeGuardGateStrategy

app_repo = tmp_root / "app-server-repo"
hooks_dir = app_repo / "hooks"
hooks_dir.mkdir(parents=True, exist_ok=True)

(app_repo / "tracked.py").write_text("print('base')\n", encoding="utf-8")
subprocess.run(["git", "init"], cwd=app_repo, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
subprocess.run(["git", "add", "tracked.py"], cwd=app_repo, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
subprocess.run(
    ["git", "-c", "user.name=CI", "-c", "user.email=ci@vibeguard.test", "commit", "-m", "init"],
    cwd=app_repo,
    check=True,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
(app_repo / "tracked.py").write_text("print('changed')\n", encoding="utf-8")
(app_repo / "new_file.py").write_text("print('new')\n", encoding="utf-8")

(hooks_dir / "pre-bash-guard.sh").write_text(
    """#!/usr/bin/env bash
cat >/dev/null
python3 - <<'PY'
import json
import os
msg = 'rewrite=' + '|'.join([
    os.environ.get('VIBEGUARD_SESSION_ID', ''),
    os.environ.get('VIBEGUARD_THREAD_ID', ''),
    os.environ.get('VIBEGUARD_TURN_ID', ''),
])
print(json.dumps({'decision': 'allow', 'updatedInput': {'command': msg}}))
PY
""",
    encoding="utf-8",
)
(hooks_dir / "stop-guard.sh").write_text(
    "#!/usr/bin/env bash\ncat >/dev/null\n",
    encoding="utf-8",
)
(hooks_dir / "learn-evaluator.sh").write_text(
    """#!/usr/bin/env bash
cat >/dev/null
python3 - <<'PY'
import json
import os
msg = 'learn=' + '|'.join([
    os.environ.get('VIBEGUARD_SESSION_ID', ''),
    os.environ.get('VIBEGUARD_THREAD_ID', ''),
    os.environ.get('VIBEGUARD_TURN_ID', ''),
])
print(json.dumps({'stopReason': msg}))
PY
""",
    encoding="utf-8",
)
(hooks_dir / "post-build-check.sh").write_text(
    """#!/usr/bin/env bash
payload=$(cat)
PAYLOAD="$payload" python3 - <<'PY'
import json
import os
payload = json.loads(os.environ['PAYLOAD'])
file_path = payload['tool_input']['file_path']
msg = 'build=' + '|'.join([
    os.environ.get('VIBEGUARD_SESSION_ID', ''),
    os.environ.get('VIBEGUARD_THREAD_ID', ''),
    os.environ.get('VIBEGUARD_TURN_ID', ''),
    os.path.basename(file_path),
])
print(json.dumps({'hookSpecificOutput': {'hookEventName': 'PostToolUse', 'additionalContext': msg}}))
PY
""",
    encoding="utf-8",
)

for hook in hooks_dir.iterdir():
    hook.chmod(0o755)

strategy = VibeGuardGateStrategy(app_repo)
state = SessionState()
strategy.on_client_message(
    {"method": "thread/start", "params": {"threadId": "thread/alpha", "cwd": str(app_repo)}},
    state,
)
strategy.on_client_message(
    {"method": "turn/start", "params": {"threadId": "thread/alpha", "cwd": str(app_repo), "turnId": "turn-42"}},
    state,
)

captured = []
approval_message = {
    "id": "req-1",
    "method": "item/commandExecution/requestApproval",
    "params": {"threadId": "thread/alpha", "command": "npm install"},
}
intercepted = strategy.handle_server_request(approval_message, state, captured.append)

completed = strategy.on_server_notification(
    {"method": "turn/completed", "params": {"threadId": "thread/alpha", "turnId": "turn-42"}},
    state,
)

print(
    json.dumps(
        {
            "intercepted": intercepted,
            "approval": captured[0],
            "completed": completed,
            "session_collision_free": module._session_id_for_thread("thread/alpha")
            != module._session_id_for_thread("thread-alpha"),
        },
        ensure_ascii=False,
    )
)
PYCODE
)"

assert_contains "${adapter_json}" '"intercepted": true' "app-server adapter intercepts approval requests with rewritten commands"
assert_contains "${adapter_json}" 'rewrite=codex-thread-thread-alpha-' "pre-bash hook receives a normalized hashed session id"
assert_contains "${adapter_json}" '|thread/alpha|turn-42' "pre-bash hook receives explicit thread/turn context"
assert_contains "${adapter_json}" '"vibeguard"' "turn/completed notification is enriched with vibeguard feedback"
assert_contains "${adapter_json}" 'learn=codex-thread-thread-alpha-' "learn-evaluator feedback is attached to turn/completed"
assert_contains "${adapter_json}" 'build=codex-thread-thread-alpha-' "post-build feedback is attached to turn/completed"
assert_contains "${adapter_json}" 'tracked.py' "post-build check still covers modified tracked source files"
assert_contains "${adapter_json}" 'new_file.py' "post-build check covers untracked source files"
assert_contains "${adapter_json}" '"session_collision_free": true' "distinct thread ids do not collapse to the same session id"
assert_contains "${adapter_json}" '"pre_edit_guard": false' "capability matrix is exposed on app-server feedback"
assert_not_contains "${adapter_json}" '"stop-guard.sh"' "empty stop-guard output does not create spurious feedback entries"

header "app-server adapter fails closed when pre-bash hook exits nonzero"
app_server_failure_json="$(python3 - "${REPO_DIR}" "${TMP_DIR}" <<'PYCODE'
import json
import importlib.util
import pathlib
import sys

repo_dir = pathlib.Path(sys.argv[1])
tmp_root = pathlib.Path(sys.argv[2])
module_path = repo_dir / "scripts" / "codex" / "app_server_wrapper.py"
spec = importlib.util.spec_from_file_location("vibeguard_app_server_wrapper_fail_closed", module_path)
module = importlib.util.module_from_spec(spec)
assert spec is not None and spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
SessionState = module.SessionState
VibeGuardGateStrategy = module.VibeGuardGateStrategy

app_repo = tmp_root / "app-server-fail-closed-repo"
hooks_dir = app_repo / "hooks"
hooks_dir.mkdir(parents=True, exist_ok=True)
(hooks_dir / "pre-bash-guard.sh").write_text(
    "#!/usr/bin/env bash\ncat >/dev/null\nprintf 'boom on stderr\\n' >&2\nexit 1\n",
    encoding="utf-8",
)
(hooks_dir / "pre-bash-guard.sh").chmod(0o755)

strategy = VibeGuardGateStrategy(app_repo)
state = SessionState()
strategy.on_client_message(
    {"method": "thread/start", "params": {"threadId": "thread/alpha", "cwd": str(app_repo)}},
    state,
)

captured = []
intercepted = strategy.handle_server_request(
    {
        "id": "req-fail-1",
        "method": "item/commandExecution/requestApproval",
        "params": {"threadId": "thread/alpha", "command": "rm -rf /"},
    },
    state,
    captured.append,
)

print(json.dumps({"intercepted": intercepted, "approval": captured[0] if captured else None}, ensure_ascii=False))
PYCODE
)"
assert_contains "${app_server_failure_json}" '"intercepted": true' "app-server adapter intercepts approvals when pre-bash hook exits nonzero"
assert_contains "${app_server_failure_json}" '"decision": "decline"' "app-server adapter declines approvals when pre-bash hook exits nonzero"

header "app-server adapter fails closed on malformed non-empty pre-bash hook output"
app_server_invalid_json="$(python3 - "${REPO_DIR}" "${TMP_DIR}" <<'PYCODE'
import json
import importlib.util
import pathlib
import sys

repo_dir = pathlib.Path(sys.argv[1])
tmp_root = pathlib.Path(sys.argv[2])
module_path = repo_dir / "scripts" / "codex" / "app_server_wrapper.py"
spec = importlib.util.spec_from_file_location("vibeguard_app_server_wrapper_invalid_json", module_path)
module = importlib.util.module_from_spec(spec)
assert spec is not None and spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
SessionState = module.SessionState
VibeGuardGateStrategy = module.VibeGuardGateStrategy

app_repo = tmp_root / "app-server-invalid-json-repo"
hooks_dir = app_repo / "hooks"
hooks_dir.mkdir(parents=True, exist_ok=True)
(hooks_dir / "pre-bash-guard.sh").write_text(
    "#!/usr/bin/env bash\ncat >/dev/null\nprintf '{'\n",
    encoding="utf-8",
)
(hooks_dir / "pre-bash-guard.sh").chmod(0o755)

strategy = VibeGuardGateStrategy(app_repo)
state = SessionState()
strategy.on_client_message(
    {"method": "thread/start", "params": {"threadId": "thread/alpha", "cwd": str(app_repo)}},
    state,
)

captured = []
intercepted = strategy.handle_server_request(
    {
        "id": "req-invalid-json-1",
        "method": "item/commandExecution/requestApproval",
        "params": {"threadId": "thread/alpha", "command": "git push --force"},
    },
    state,
    captured.append,
)

print(json.dumps({"intercepted": intercepted, "approval": captured[0] if captured else None}, ensure_ascii=False))
PYCODE
)"
assert_contains "${app_server_invalid_json}" '"intercepted": true' "app-server adapter intercepts approvals when pre-bash hook output is malformed"
assert_contains "${app_server_invalid_json}" '"decision": "decline"' "app-server adapter declines approvals when pre-bash hook output is malformed"

header "app-server adapter surfaces warn decisions before forwarding approval"
warn_hook_json="$(python3 - "${REPO_DIR}" "${TMP_DIR}" <<'PYCODE'
import json
import importlib.util
import pathlib
import sys

repo_dir = pathlib.Path(sys.argv[1])
tmp_root = pathlib.Path(sys.argv[2])
module_path = repo_dir / "scripts" / "codex" / "app_server_wrapper.py"
spec = importlib.util.spec_from_file_location("vibeguard_app_server_wrapper_warn_hook", module_path)
module = importlib.util.module_from_spec(spec)
assert spec is not None and spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
SessionState = module.SessionState
VibeGuardGateStrategy = module.VibeGuardGateStrategy

app_repo = tmp_root / "app-server-repo-warn-hook"
hooks_dir = app_repo / "hooks"
hooks_dir.mkdir(parents=True, exist_ok=True)

(hooks_dir / "pre-bash-guard.sh").write_text(
    "#!/usr/bin/env bash\ncat >/dev/null\npython3 - <<'PY'\nimport json\nprint(json.dumps({'decision': 'warn', 'reason': 'warn only'}))\nPY\n",
    encoding="utf-8",
)
(hooks_dir / "pre-bash-guard.sh").chmod(0o755)

strategy = VibeGuardGateStrategy(app_repo)
state = SessionState()
strategy.on_client_message(
    {"method": "thread/start", "params": {"threadId": "thread/warn", "cwd": str(app_repo)}},
    state,
)

captured = []
approval_message = {
    "id": "req-warn",
    "method": "item/commandExecution/requestApproval",
    "params": {"threadId": "thread/warn", "command": "printf test > notes.md"},
}
intercepted = strategy.handle_server_request(approval_message, state, captured.append)

print(json.dumps({"intercepted": intercepted, "captured": captured}, ensure_ascii=False))
PYCODE
)"
assert_contains "${warn_hook_json}" '"intercepted": false' "warn pre-bash hook leaves approval request untouched"
assert_contains "${warn_hook_json}" '"method": "warning"' "warn pre-bash hook emits a visible warning notification"
assert_contains "${warn_hook_json}" '"message": "warn only"' "warn pre-bash hook preserves the warning reason"
assert_contains "${warn_hook_json}" '"threadId": "thread/warn"' "warn notification targets the active thread"

header "app-server adapter fails closed on unexpected hook decisions"
unknown_decision_json="$(python3 - "${REPO_DIR}" "${TMP_DIR}" <<'PYCODE'
import json
import importlib.util
import pathlib
import sys

repo_dir = pathlib.Path(sys.argv[1])
tmp_root = pathlib.Path(sys.argv[2])
module_path = repo_dir / "scripts" / "codex" / "app_server_wrapper.py"
spec = importlib.util.spec_from_file_location("vibeguard_app_server_wrapper_unknown_decision", module_path)
module = importlib.util.module_from_spec(spec)
assert spec is not None and spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
SessionState = module.SessionState
VibeGuardGateStrategy = module.VibeGuardGateStrategy

app_repo = tmp_root / "app-server-repo-unknown-decision"
hooks_dir = app_repo / "hooks"
hooks_dir.mkdir(parents=True, exist_ok=True)

(hooks_dir / "pre-bash-guard.sh").write_text(
    "#!/usr/bin/env bash\ncat >/dev/null\npython3 - <<'PY'\nimport json\nprint(json.dumps({'decision': 'banana', 'reason': 'bad protocol'}))\nPY\n",
    encoding="utf-8",
)
(hooks_dir / "pre-bash-guard.sh").chmod(0o755)

strategy = VibeGuardGateStrategy(app_repo)
state = SessionState()
strategy.on_client_message(
    {"method": "thread/start", "params": {"threadId": "thread/unknown", "cwd": str(app_repo)}},
    state,
)

captured = []
approval_message = {
    "id": "req-unknown",
    "method": "item/commandExecution/requestApproval",
    "params": {"threadId": "thread/unknown", "command": "echo hi"},
}
intercepted = strategy.handle_server_request(approval_message, state, captured.append)

print(json.dumps({"intercepted": intercepted, "approval": captured[0]}, ensure_ascii=False))
PYCODE
)"
assert_contains "${unknown_decision_json}" '"intercepted": true' "unexpected decisions intercept the approval request"
assert_contains "${unknown_decision_json}" '"decision": "decline"' "unexpected decisions fail closed instead of approving"

header "app-server adapter fails closed when pre-bash hook cannot launch"
launch_error_json="$(python3 - "${REPO_DIR}" "${TMP_DIR}" <<'PYCODE'
import json
import importlib.util
import pathlib
import sys

repo_dir = pathlib.Path(sys.argv[1])
tmp_root = pathlib.Path(sys.argv[2])
module_path = repo_dir / "scripts" / "codex" / "app_server_wrapper.py"
spec = importlib.util.spec_from_file_location("vibeguard_app_server_wrapper_launch_error", module_path)
module = importlib.util.module_from_spec(spec)
assert spec is not None and spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
SessionState = module.SessionState
VibeGuardGateStrategy = module.VibeGuardGateStrategy

app_repo = tmp_root / "app-server-repo-launch-error"
hooks_dir = app_repo / "hooks"
hooks_dir.mkdir(parents=True, exist_ok=True)

(hooks_dir / "pre-bash-guard.sh").write_text(
    "#!/usr/bin/env bash\ncat >/dev/null\nprintf '{\"decision\":\"pass\"}'\n",
    encoding="utf-8",
)
(hooks_dir / "pre-bash-guard.sh").chmod(0o755)

strategy = VibeGuardGateStrategy(app_repo)
state = SessionState()
strategy.on_client_message(
    {"method": "thread/start", "params": {"threadId": "thread/launch-error", "cwd": str(app_repo / 'missing-cwd')}},
    state,
)

captured = []
approval_message = {
    "id": "req-launch-error",
    "method": "item/commandExecution/requestApproval",
    "params": {"threadId": "thread/launch-error", "command": "echo hi"},
}
intercepted = strategy.handle_server_request(approval_message, state, captured.append)

print(json.dumps({"intercepted": intercepted, "approval": captured[0]}, ensure_ascii=False))
PYCODE
)"
assert_contains "${launch_error_json}" '"intercepted": true' "hook launch errors intercept the approval request"
assert_contains "${launch_error_json}" '"decision": "decline"' "hook launch errors fail closed instead of passing through"

header "app-server adapter ignores decision text from failed pre-bash hook output"
misleading_decision_hook_json="$(python3 - "${REPO_DIR}" "${TMP_DIR}" <<'PYCODE'
import json
import importlib.util
import pathlib
import sys

repo_dir = pathlib.Path(sys.argv[1])
tmp_root = pathlib.Path(sys.argv[2])
module_path = repo_dir / "scripts" / "codex" / "app_server_wrapper.py"
spec = importlib.util.spec_from_file_location("vibeguard_app_server_wrapper", module_path)
module = importlib.util.module_from_spec(spec)
assert spec is not None and spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
SessionState = module.SessionState
VibeGuardGateStrategy = module.VibeGuardGateStrategy

app_repo = tmp_root / "app-server-misleading-decision-hook-repo"
hooks_dir = app_repo / "hooks"
hooks_dir.mkdir(parents=True, exist_ok=True)

(hooks_dir / "pre-bash-guard.sh").write_text(
    "#!/usr/bin/env bash\ncat >/dev/null\necho '\"decision\":\"allow\"' >&2\nexit 1\n",
    encoding="utf-8",
)
(hooks_dir / "pre-bash-guard.sh").chmod(0o755)

strategy = VibeGuardGateStrategy(app_repo)
state = SessionState()
strategy.on_client_message(
    {"method": "thread/start", "params": {"threadId": "thread/gamma", "cwd": str(app_repo)}},
    state,
)

captured = []
approval_message = {
    "id": "req-3",
    "method": "item/commandExecution/requestApproval",
    "params": {"threadId": "thread/gamma", "command": "rm -rf ./tmp"},
}
intercepted = strategy.handle_server_request(approval_message, state, captured.append)

print(
    json.dumps(
        {
            "intercepted": intercepted,
            "approval": captured[0] if captured else None,
        },
        ensure_ascii=False,
    )
)
PYCODE
)"

assert_contains "${misleading_decision_hook_json}" '"intercepted": true' "app-server adapter intercepts approval requests when failed hook emits decision text"
assert_contains "${misleading_decision_hook_json}" '"decision": "decline"' "app-server adapter declines approval when failed hook emits decision text"
assert_not_contains "${misleading_decision_hook_json}" '"decision": "approve"' "failed hook output cannot force an approval decision"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

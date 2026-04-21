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
if [[ ${failing_rc} -ne 0 ]]; then
  green "run-hook-codex preserves a nonzero exit on wrapped hook failure"
  PASS=$((PASS + 1))
else
  red "run-hook-codex preserves a nonzero exit on wrapped hook failure"
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
cat >/dev/null
python3 - <<'PY'
import json
import os
msg = 'build=' + '|'.join([
    os.environ.get('VIBEGUARD_SESSION_ID', ''),
    os.environ.get('VIBEGUARD_THREAD_ID', ''),
    os.environ.get('VIBEGUARD_TURN_ID', ''),
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
assert_contains "${adapter_json}" '"session_collision_free": true' "distinct thread ids do not collapse to the same session id"
assert_contains "${adapter_json}" '"pre_edit_guard": false' "capability matrix is exposed on app-server feedback"
assert_not_contains "${adapter_json}" '"stop-guard.sh"' "empty stop-guard output does not create spurious feedback entries"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

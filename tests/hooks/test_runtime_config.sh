#!/usr/bin/env bash
# Runtime config wiring for ~/.vibeguard/config.json.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
hook_test_init

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR" "$VIBEGUARD_LOG_DIR"' EXIT
RUNTIME_BIN="${REPO_DIR}/vibeguard-runtime/target/debug/vibeguard-runtime"
cargo build --manifest-path "${REPO_DIR}/vibeguard-runtime/Cargo.toml" >/dev/null
export VIBEGUARD_RUNTIME="${RUNTIME_BIN}"

make_log_dir() {
  mktemp -d "$WORK_DIR/logs.XXXXXX"
}

write_cfg() {
  local path="$1" body="$2"
  printf '%s\n' "$body" > "$path"
}

new_source="$WORK_DIR/new_source.py"
prewrite_input="$WORK_DIR/prewrite.json"
python3 - "$new_source" > "$prewrite_input" <<'PY'
import json
import sys

print(json.dumps({"tool_input": {"file_path": sys.argv[1], "content": "print('new')\n"}}))
PY

run_pre_write() {
  local cfg="$1"
  shift
  env -u VIBEGUARD_WRITE_MODE VIBEGUARD_LOG_DIR="$(make_log_dir)" VIBEGUARD_CONFIG_FILE="$cfg" "$@" \
    bash hooks/pre-write-guard.sh < "$prewrite_input"
}

header "runtime config — installed hook runtime resolver"
resolver_home="$WORK_DIR/home-resolver"
resolver_hooks="${resolver_home}/.vibeguard/installed/hooks"
mkdir -p "${resolver_hooks}" "${resolver_home}/.vibeguard/installed/bin"
cp hooks/log.sh "${resolver_hooks}/log.sh"
cp -R hooks/_lib "${resolver_hooks}/_lib"
cat > "${resolver_home}/.vibeguard/installed/bin/vibeguard-runtime" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "${resolver_home}/.vibeguard/installed/bin/vibeguard-runtime"
cat > "${resolver_hooks}/vibeguard-runtime" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "${resolver_hooks}/vibeguard-runtime"
selected_hook_runtime="$(
  env -u VIBEGUARD_RUNTIME HOME="${resolver_home}" VIBEGUARD_LOG_DIR="${resolver_home}/.vibeguard" bash -c '
    source "$1"
    printf "%s" "$_VIBEGUARD_RUNTIME"
  ' bash "${resolver_hooks}/log.sh"
)"
assert_contains "$selected_hook_runtime" "${resolver_home}/.vibeguard/installed/bin/vibeguard-runtime" "installed hook log resolver prefers installed runtime"

header "runtime config — pre-write write_mode"
cfg="$WORK_DIR/config.json"
write_cfg "$cfg" '{"write_mode":"block"}'
result=$(run_pre_write "$cfg")
assert_contains "$result" '"decision": "block"' "JSON write_mode=block hard-blocks new source writes"

result=$(run_pre_write "$cfg" VIBEGUARD_WRITE_MODE=warn)
assert_not_contains "$result" '"decision": "block"' "env write_mode=warn overrides JSON block"
assert_contains "$result" "hookSpecificOutput" "env write_mode=warn emits advisory"

write_cfg "$cfg" '{"write_mode":"sensitive-invalid-mode"}'
set +e
result=$(run_pre_write "$cfg" 2>&1)
invalid_mode_rc=$?
set -e
assert_exit_zero "invalid JSON write_mode fails visibly with exit 30" test "$invalid_mode_rc" = "30"
assert_contains "$result" "category=config_enum_error" "invalid JSON write_mode reports enum category"
assert_not_contains "$result" "sensitive-invalid-mode" "invalid JSON write_mode does not leak value"

header "runtime config — circuit breaker"
write_cfg "$cfg" '{"circuit_breaker":{"threshold":1,"cooldown_seconds":42}}'
cb_values=$(VIBEGUARD_LOG_DIR="$(make_log_dir)" VIBEGUARD_SESSION_ID="cfg-cb-values" VIBEGUARD_CONFIG_FILE="$cfg" bash -c '
  set -euo pipefail
  source hooks/log.sh
  source hooks/circuit-breaker.sh
  printf "%s:%s" "$CB_THRESHOLD" "$CB_COOLDOWN"
')
assert_contains "$cb_values" "1:42" "JSON circuit_breaker threshold/cooldown are loaded"

cb_trip=$(VIBEGUARD_LOG_DIR="$(make_log_dir)" VIBEGUARD_SESSION_ID="cfg-cb-trip" VIBEGUARD_CONFIG_FILE="$cfg" bash -c '
  set -euo pipefail
  source hooks/log.sh
  source hooks/circuit-breaker.sh
  vg_cb_check "runtime-config-test"
  vg_cb_record_block "runtime-config-test"
  if vg_cb_check "runtime-config-test"; then
    printf "still-closed"
  else
    printf "open"
  fi
')
assert_contains "$cb_trip" "open" "JSON circuit_breaker.threshold=1 opens after one block"

cb_env_values=$(VIBEGUARD_LOG_DIR="$(make_log_dir)" VIBEGUARD_SESSION_ID="cfg-cb-env" VIBEGUARD_CONFIG_FILE="$cfg" VG_CB_THRESHOLD=4 VG_CB_COOLDOWN=55 bash -c '
  set -euo pipefail
  source hooks/log.sh
  source hooks/circuit-breaker.sh
  printf "%s:%s" "$CB_THRESHOLD" "$CB_COOLDOWN"
')
assert_contains "$cb_env_values" "4:55" "circuit breaker env vars override JSON"

header "runtime config — analysis paralysis"
seed_research_events() {
  local log_dir="$1" session="$2" count="$3" log_file
  log_file=$(VIBEGUARD_LOG_DIR="$log_dir" VIBEGUARD_SESSION_ID="$session" bash -c 'source hooks/log.sh; printf "%s" "$VIBEGUARD_LOG_FILE"')
  mkdir -p "$(dirname "$log_file")"
python3 - "$log_file" "$session" "$count" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone

log_file, session, count = sys.argv[1], sys.argv[2], int(sys.argv[3])
now = datetime.now(timezone.utc)
with open(log_file, "w", encoding="utf-8") as f:
    for i in range(count):
        ts = now - timedelta(seconds=count - i)
        f.write(json.dumps({
            "ts": ts.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "session": session,
            "hook": "analysis-paralysis-guard",
            "tool": "Read",
            "decision": "pass",
            "reason": "",
            "detail": "",
        }) + "\n")
PY
}

write_cfg "$cfg" '{"paralysis":{"threshold":2}}'
paralysis_log="$(make_log_dir)"
seed_research_events "$paralysis_log" "cfg-paralysis-json" 2
result=$(env CI=false GITHUB_ACTIONS=false TRAVIS=false CIRCLECI=false JENKINS_URL= GITLAB_CI=false TF_BUILD=false \
  VIBEGUARD_LOG_DIR="$paralysis_log" VIBEGUARD_SESSION_ID="cfg-paralysis-json" VIBEGUARD_CONFIG_FILE="$cfg" \
  bash hooks/analysis-paralysis-guard.sh)
assert_contains "$result" "ANALYSIS PARALYSIS" "JSON paralysis.threshold=2 triggers warning"

paralysis_suppressed_log="$(make_log_dir)"
seed_research_events "$paralysis_suppressed_log" "cfg-paralysis-suppressed" 2
result=$(env CI=false GITHUB_ACTIONS=false TRAVIS=false CIRCLECI=false JENKINS_URL= GITLAB_CI=false TF_BUILD=false \
  VIBEGUARD_LOG_DIR="$paralysis_suppressed_log" VIBEGUARD_SESSION_ID="cfg-paralysis-suppressed" VIBEGUARD_CONFIG_FILE="$cfg" \
  VIBEGUARD_SUPPRESS_PARALYSIS=1 bash hooks/analysis-paralysis-guard.sh)
assert_not_contains "$result" "ANALYSIS PARALYSIS" "VIBEGUARD_SUPPRESS_PARALYSIS disables read-only agent warning"

paralysis_env_log="$(make_log_dir)"
seed_research_events "$paralysis_env_log" "cfg-paralysis-env" 2
result=$(env CI=false GITHUB_ACTIONS=false TRAVIS=false CIRCLECI=false JENKINS_URL= GITLAB_CI=false TF_BUILD=false \
  VIBEGUARD_LOG_DIR="$paralysis_env_log" VIBEGUARD_SESSION_ID="cfg-paralysis-env" VIBEGUARD_CONFIG_FILE="$cfg" \
  VG_PARALYSIS_THRESHOLD=5 bash hooks/analysis-paralysis-guard.sh)
assert_not_contains "$result" "ANALYSIS PARALYSIS" "VG_PARALYSIS_THRESHOLD overrides JSON"

paralysis_drain_log="$(make_log_dir)"
seed_research_events "$paralysis_drain_log" "cfg-paralysis-drain" 2
paralysis_drain_out=$(node - "${REPO_DIR}" "$paralysis_drain_log" "$cfg" <<'NODE'
const { spawn } = require('node:child_process');

const [repoDir, logDir, configFile] = process.argv.slice(2);
const child = spawn('bash', ['hooks/analysis-paralysis-guard.sh'], {
  cwd: repoDir,
  env: {
    ...process.env,
    CI: 'false',
    GITHUB_ACTIONS: 'false',
    TRAVIS: 'false',
    CIRCLECI: 'false',
    JENKINS_URL: '',
    GITLAB_CI: 'false',
    TF_BUILD: 'false',
    VIBEGUARD_LOG_DIR: logDir,
    VIBEGUARD_SESSION_ID: 'cfg-paralysis-drain',
    VIBEGUARD_CONFIG_FILE: configFile,
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
  tool_name: 'Read',
  tool_input: {
    file_path: '/tmp/example',
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
    stdout: stdout.slice(0, 500),
    stderr: stderr.slice(0, 120),
  }));
});
NODE
)
assert_contains "$paralysis_drain_out" '"code":0' "analysis-paralysis warning path exits cleanly after large stdin"
assert_contains "$paralysis_drain_out" '"stdinError":""' "analysis-paralysis drains large stdin before warning"
assert_contains "$paralysis_drain_out" "ANALYSIS PARALYSIS" "analysis-paralysis still emits warning after draining large stdin"

paralysis_cb_error_log="$(make_log_dir)"
seed_research_events "$paralysis_cb_error_log" "cfg-paralysis-cb-error" 2
lock_file=$(VIBEGUARD_LOG_DIR="$paralysis_cb_error_log" VIBEGUARD_SESSION_ID="cfg-paralysis-cb-error" bash -c 'source hooks/log.sh; source hooks/circuit-breaker.sh; _vg_cb_lock_file "analysis-paralysis-guard"')
mkdir -p "$(dirname "$lock_file")"
if command -v flock >/dev/null 2>&1; then
  ready_file="${paralysis_cb_error_log}/lock-ready"
  (
    exec 8>"$lock_file"
    flock -x 8
    : > "$ready_file"
    sleep 1
  ) &
  lock_holder=$!
  while [[ ! -f "$ready_file" ]]; do sleep 0.01; done
  result=$(env CI=false GITHUB_ACTIONS=false TRAVIS=false CIRCLECI=false JENKINS_URL= GITLAB_CI=false TF_BUILD=false \
    VIBEGUARD_LOG_DIR="$paralysis_cb_error_log" VIBEGUARD_SESSION_ID="cfg-paralysis-cb-error" VIBEGUARD_CONFIG_FILE="$cfg" \
    VG_CB_LOCK_TIMEOUT_SECONDS=0 bash hooks/analysis-paralysis-guard.sh 2>&1)
  wait "$lock_holder" 2>/dev/null || true
  unset lock_holder ready_file
else
  mkdir "${lock_file}.d"
  result=$(env CI=false GITHUB_ACTIONS=false TRAVIS=false CIRCLECI=false JENKINS_URL= GITLAB_CI=false TF_BUILD=false \
    VIBEGUARD_LOG_DIR="$paralysis_cb_error_log" VIBEGUARD_SESSION_ID="cfg-paralysis-cb-error" VIBEGUARD_CONFIG_FILE="$cfg" \
    VG_CB_LOCK_TIMEOUT_SECONDS=0 bash hooks/analysis-paralysis-guard.sh 2>&1)
  rmdir "${lock_file}.d"
fi
assert_contains "$result" "VIBEGUARD circuit breaker state error" "analysis-paralysis CB lock error is visible"
unset lock_file

header "runtime config — U-16"
big_write_input="$WORK_DIR/big-write.json"
python3 - "$WORK_DIR/big.py" > "$big_write_input" <<'PY'
import json
import sys

content = "\n".join(f"x = {i}" for i in range(850))
print(json.dumps({"tool_input": {"file_path": sys.argv[1], "content": content}}))
PY

write_cfg "$cfg" '{"u16":{"limit":1500}}'
result=$(VIBEGUARD_LOG_DIR="$(make_log_dir)" VIBEGUARD_CONFIG_FILE="$cfg" bash hooks/pre-write-guard.sh < "$big_write_input")
assert_not_contains "$result" '"decision": "block"' "JSON u16.limit=1500 allows 850-line source write"

result=$(VIBEGUARD_LOG_DIR="$(make_log_dir)" VIBEGUARD_CONFIG_FILE="$cfg" VG_U16_LIMIT=500 bash hooks/pre-write-guard.sh < "$big_write_input")
assert_contains "$result" '"decision": "block"' "VG_U16_LIMIT overrides JSON u16.limit"
assert_contains "$result" "500-line" "U-16 block cites env-overridden limit"

header "runtime config — helper functions"
unit_cfg="$WORK_DIR/unit-config.json"
write_cfg "$unit_cfg" '{"u16":{"limit":1234},"write_mode":"block"}'
VIBEGUARD_CONFIG_FILE="$unit_cfg"
unset VG_TEST_X VG_TEST_MODE
source hooks/_lib/config.sh
got=$(vg_config_get_int VG_TEST_X u16.limit 800)
[[ "$got" == "1234" ]] && green "vg_config_get_int reads JSON int" || { red "vg_config_get_int JSON int (got: $got)"; FAIL=$((FAIL + 1)); }
TOTAL=$((TOTAL + 1)); [[ "$got" == "1234" ]] && PASS=$((PASS + 1))

VG_TEST_X=999
got=$(vg_config_get_int VG_TEST_X u16.limit 800)
[[ "$got" == "999" ]] && green "vg_config_get_int env beats JSON" || { red "vg_config_get_int env (got: $got)"; FAIL=$((FAIL + 1)); }
TOTAL=$((TOTAL + 1)); [[ "$got" == "999" ]] && PASS=$((PASS + 1))
unset VG_TEST_X

got=$(vg_config_get_str VG_TEST_MODE write_mode warn)
[[ "$got" == "block" ]] && green "vg_config_get_str reads JSON string" || { red "vg_config_get_str JSON string (got: $got)"; FAIL=$((FAIL + 1)); }
TOTAL=$((TOTAL + 1)); [[ "$got" == "block" ]] && PASS=$((PASS + 1))

VG_TEST_MODE=warn
got=$(vg_config_get_str VG_TEST_MODE write_mode block)
[[ "$got" == "warn" ]] && green "vg_config_get_str env beats JSON" || { red "vg_config_get_str env (got: $got)"; FAIL=$((FAIL + 1)); }
TOTAL=$((TOTAL + 1)); [[ "$got" == "warn" ]] && PASS=$((PASS + 1))

cache_runtime="$WORK_DIR/cache-runtime"
cache_log="$WORK_DIR/cache-runtime.log"
cat > "$cache_runtime" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${VIBEGUARD_RUNTIME_COMMAND_LOG:?}"
case "${1:-}" in
  runtime-config-validate)
    printf 'VALID\n'
    ;;
  runtime-config-get-int)
    case "${2:-}" in
      __VIBEGUARD_CONFIG_PROBE_INT__) printf '19\n' ;;
      VG_TEST_X) printf '1234\n' ;;
      *) printf '%s\n' "${4:-}" ;;
    esac
    ;;
  runtime-config-get-str)
    case "${2:-}" in
      __VIBEGUARD_CONFIG_PROBE_STR__) printf 'block\n' ;;
      VG_TEST_MODE) printf 'block\n' ;;
      *) printf '%s\n' "${4:-}" ;;
    esac
    ;;
  *)
    exit 2
    ;;
esac
SH
chmod +x "$cache_runtime"
cache_out="$(
  VIBEGUARD_RUNTIME="$cache_runtime" VIBEGUARD_CONFIG_FILE="$unit_cfg" VIBEGUARD_RUNTIME_COMMAND_LOG="$cache_log" bash -c '
    source hooks/_lib/config.sh
    vg_config_get_int_result first VG_TEST_X u16.limit 800
    vg_config_get_str_result second VG_TEST_MODE write_mode warn
    vg_config_get_int_result third VG_TEST_X u16.limit 800
    printf "%s/%s/%s" "$first" "$second" "$third"
  '
)"
assert_contains "$cache_out" "1234/block/1234" "runtime config cache preserves config values"
cache_commands="$(cat "$cache_log")"
assert_occurrences "$cache_commands" "runtime-config-validate" "1" "runtime config resolver probes validator support once per process"
assert_occurrences "$cache_commands" "runtime-config-get-int __VIBEGUARD_CONFIG_PROBE_INT__ u16.limit 17" "1" "runtime config resolver probes int support once per process"
assert_occurrences "$cache_commands" "runtime-config-get-str __VIBEGUARD_CONFIG_PROBE_STR__ write_mode probe-default" "1" "runtime config resolver probes str support once per process"
assert_occurrences "$cache_commands" "runtime-config-get-int VG_TEST_X u16.limit 800" "2" "runtime config cache still performs requested int reads"
assert_occurrences "$cache_commands" "runtime-config-get-str VG_TEST_MODE write_mode warn" "1" "runtime config cache still performs requested str reads"

partial_runtime="$WORK_DIR/partial-runtime"
cat > "$partial_runtime" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "json-field" ]]; then
  exit 0
fi
echo "missing helper: ${1:-}" >&2
exit 2
SH
chmod +x "$partial_runtime"
unset VG_TEST_X
got=$(VIBEGUARD_RUNTIME="$partial_runtime" vg_config_get_int VG_TEST_X u16.limit 800)
[[ "$got" == "1234" ]] && green "vg_config_get_int skips runtimes missing config helpers" || { red "vg_config_get_int stale runtime fallback (got: $got)"; FAIL=$((FAIL + 1)); }
TOTAL=$((TOTAL + 1)); [[ "$got" == "1234" ]] && PASS=$((PASS + 1))

default_only_runtime="$WORK_DIR/default-only-runtime"
cat > "$default_only_runtime" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  runtime-config-validate)
    printf 'VALID\n'
    ;;
  runtime-config-get-int|runtime-config-get-str)
    printf '%s\n' "${4:?}"
    ;;
  *)
    exit 2
    ;;
esac
SH
chmod +x "$default_only_runtime"
unset VG_TEST_MODE
got=$(VIBEGUARD_RUNTIME="$default_only_runtime" vg_config_get_str VG_TEST_MODE write_mode warn)
[[ "$got" == "block" ]] && green "vg_config_get_str rejects runtimes that cannot read JSON values" || { red "vg_config_get_str default-only runtime fallback (got: $got)"; FAIL=$((FAIL + 1)); }
TOTAL=$((TOTAL + 1)); [[ "$got" == "block" ]] && PASS=$((PASS + 1))

assert_not_contains "$(sed -n '1,180p' hooks/_lib/config.sh)" "python3" "runtime config helper no longer shells out to python3"

hook_test_finish

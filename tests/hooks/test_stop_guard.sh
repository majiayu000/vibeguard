#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
hook_test_init

run_stop_no_ci() {
  local repo_dir="$1" log_dir="$2" input="$3"
  (
    cd "$repo_dir"
    env -u CI -u GITHUB_ACTIONS -u TRAVIS -u CIRCLECI -u JENKINS_URL -u GITLAB_CI -u TF_BUILD \
      VIBEGUARD_LOG_DIR="$log_dir" \
      bash "$REPO_DIR/hooks/stop-guard.sh" <<< "$input"
  )
}

header "stop-guard.sh — missing runtime reports explicit failure"

runtime_missing_dir=$(mktemp -d)
mkdir -p "$runtime_missing_dir/home" "$runtime_missing_dir/hooks"
cp hooks/stop-guard.sh "$runtime_missing_dir/hooks/"
set +e
runtime_missing_output=$(
  env -u VIBEGUARD_RUNTIME HOME="$runtime_missing_dir/home" \
    bash "$runtime_missing_dir/hooks/stop-guard.sh" <<< '{"hook_event_name":"Stop"}' 2>&1
)
runtime_missing_rc=$?
set -e
assert_contains "rc=$runtime_missing_rc" "rc=2" "missing runtime exits nonzero instead of silently passing"
assert_contains "$runtime_missing_output" "vibeguard-runtime not found" "missing runtime reports explicit install/build error"
rm -rf "$runtime_missing_dir"

header "stop-guard.sh — Stop loop guard skips logging"

stop_repo=$(mktemp -d)
stop_log=$(mktemp -d)
git -C "$stop_repo" init >/dev/null
git -C "$stop_repo" config user.email test@example.com
git -C "$stop_repo" config user.name "Test User"
mkdir -p "$stop_repo/src"
printf 'pub fn value() -> i32 { 1 }\n' > "$stop_repo/src/lib.rs"
git -C "$stop_repo" add src/lib.rs
git -C "$stop_repo" commit -m initial >/dev/null
printf 'pub fn value() -> i32 { 2 }\n' > "$stop_repo/src/lib.rs"

run_stop_no_ci "$stop_repo" "$stop_log" '{"hook_event_name":"Stop","stop_hook_active":true}' >/dev/null
assert_exit_zero "stop_hook_active skip does not create a global event log" \
  bash -c '[[ ! -e "$1/events.jsonl" ]]' _ "$stop_log"

header "stop-guard.sh — uncommitted source changes are logged, not blocked"

run_stop_no_ci "$stop_repo" "$stop_log" '{"hook_event_name":"Stop"}' >/tmp/vg-stop-out.txt
stop_output="$(cat /tmp/vg-stop-out.txt)"
assert_not_contains "$stop_output" '"decision": "block"' "Stop hook does not block when source changes exist"
stop_events="$(cat "$stop_log/events.jsonl")"
assert_contains "$stop_events" '"hook": "stop-guard"' "Stop hook writes an event"
assert_contains "$stop_events" '"decision": "gate"' "Stop hook records gate decision"
assert_contains "$stop_events" 'uncommitted source changes: 1 files' "Stop hook counts changed source files"
assert_contains "$stop_events" 'src/lib.rs ' "Stop hook records changed source detail"

rm -rf "$stop_repo" "$stop_log" /tmp/vg-stop-out.txt

hook_test_finish

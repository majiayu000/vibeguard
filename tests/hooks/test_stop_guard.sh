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

header "stop-guard.sh — W-16 unverified-stop advisory (issue #674)"

verify_repo=$(mktemp -d)
verify_log=$(mktemp -d)
git -C "$verify_repo" init >/dev/null
git -C "$verify_repo" config user.email test@example.com
git -C "$verify_repo" config user.name "Test User"
printf '[package]\nname = "probe"\nversion = "0.0.1"\n' > "$verify_repo/Cargo.toml"
git -C "$verify_repo" add Cargo.toml
git -C "$verify_repo" commit -m initial >/dev/null

_verify_hash=$(printf '%s' "$(cd "$verify_repo" && pwd -P)" | shasum -a 256 | cut -c1-8)
_verify_project_log="$verify_log/projects/${_verify_hash}/events.jsonl"
mkdir -p "$(dirname "$_verify_project_log")"

seed_verify_event() {
  local hook="$1" tool="$2" detail="$3"
  printf '{"ts":"%s","session":"stop-verify-session","hook":"%s","tool":"%s","decision":"pass","detail":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$hook" "$tool" "$detail" >> "$_verify_project_log"
}

run_stop_verify() {
  (
    cd "$verify_repo"
    env -u CI -u GITHUB_ACTIONS -u TRAVIS -u CIRCLECI -u JENKINS_URL -u GITLAB_CI -u TF_BUILD \
      VIBEGUARD_LOG_DIR="$verify_log" VIBEGUARD_SESSION_ID="stop-verify-session" \
      "$@" bash "$REPO_DIR/hooks/stop-guard.sh" <<< '{"hook_event_name":"Stop"}'
  )
}

seed_verify_event "pre-edit-guard" "Edit" "$verify_repo/src/lib.rs"
unverified_output="$(run_stop_verify)"
assert_contains "$unverified_output" "[W-16]" "source edit with no verification emits W-16 advisory"
assert_contains "$unverified_output" "cargo test" "advisory suggests the detected toolchain command"
assert_contains "$unverified_output" "src/lib.rs" "advisory names the edited file"
assert_contains "$(cat "$_verify_project_log")" "stop without verification evidence" "advisory records trackable warn event"

: > "$_verify_project_log"
seed_verify_event "pre-edit-guard" "Edit" "$verify_repo/src/lib.rs"
seed_verify_event "pre-bash-guard" "Bash" "cargo test -q"
verified_output="$(run_stop_verify)"
assert_not_contains "$verified_output" "[W-16]" "verification command in session silences the advisory"

: > "$_verify_project_log"
seed_verify_event "pre-edit-guard" "Edit" "$verify_repo/tests/helper.rs"
test_only_output="$(run_stop_verify)"
assert_not_contains "$test_only_output" "[W-16]" "test-path-only edits do not trigger the advisory"

: > "$_verify_project_log"
seed_verify_event "pre-edit-guard" "Edit" "$verify_repo/src/lib.rs"
suppressed_output="$(run_stop_verify VIBEGUARD_SUPPRESS_STOP_VERIFY=1)"
assert_not_contains "$suppressed_output" "[W-16]" "VIBEGUARD_SUPPRESS_STOP_VERIFY=1 suppresses the advisory"

rm -f "$verify_repo/Cargo.toml"
git -C "$verify_repo" rm -q --cached Cargo.toml 2>/dev/null || true
: > "$_verify_project_log"
seed_verify_event "pre-edit-guard" "Edit" "$verify_repo/src/lib.rs"
no_toolchain_output="$(run_stop_verify)"
assert_not_contains "$no_toolchain_output" "[W-16]" "repos without a known toolchain skip the advisory"

rm -rf "$verify_repo" "$verify_log"

hook_test_finish

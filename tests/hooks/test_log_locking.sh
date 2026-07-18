#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
hook_test_init

header "log.sh — lock contention"

lock_test_dir="$(mktemp -d)"
lock_test_file="${lock_test_dir}/events.jsonl"
lock_test_stderr="${lock_test_dir}/stderr"
: > "$lock_test_file"
mkdir "${lock_test_file}.lock.d"

set +e
lock_result=$(
  export VIBEGUARD_LOG_LOCK_ATTEMPTS=1
  export VIBEGUARD_LOG_LOCK_SLEEP_SECONDS=0
  source hooks/_lib/log_write.sh
  vg_append_log_line "$lock_test_file" '{"locked":true}' 2>"$lock_test_stderr"
  printf 'rc=%s' "$?"
)
set -e

assert_contains "$lock_result" "rc=1" "Log append lock contention returns nonzero"
assert_contains "$(cat "$lock_test_stderr")" "failed to acquire log lock" "Log append lock contention reports diagnostic"
assert_not_contains "$(cat "$lock_test_file")" '{"locked":true}' "Log append lock contention does not write unlocked"
rm -rf "$lock_test_dir"

stale_shell_lock_dir="$(mktemp -d)"
stale_shell_lock_file="${stale_shell_lock_dir}/events.jsonl"
mkdir "${stale_shell_lock_file}.lock.d"
set +e
stale_shell_lock_result=$(
  export VIBEGUARD_LOG_LOCK_ATTEMPTS=1
  export VIBEGUARD_LOG_LOCK_SLEEP_SECONDS=0
  export VIBEGUARD_LOG_LOCK_STALE_SECONDS=0
  source hooks/_lib/log_write.sh
  vg_append_log_line "$stale_shell_lock_file" '{"stale_shell_lock":true}'
  printf 'rc=%s' "$?"
)
set -e
assert_contains "$stale_shell_lock_result" "rc=0" "Shell log append removes stale lock and succeeds"
assert_contains "$(cat "$stale_shell_lock_file")" '{"stale_shell_lock":true}' "Shell stale-lock recovery writes the log line"
assert_exit_zero "Shell stale-lock recovery removes lock directory" test ! -e "${stale_shell_lock_file}.lock.d"
rm -rf "$stale_shell_lock_dir"

gnu_stat_lock_dir="$(mktemp -d)"
gnu_stat_bin="${gnu_stat_lock_dir}/bin"
gnu_stat_lock_file="${gnu_stat_lock_dir}/events.jsonl"
mkdir -p "$gnu_stat_bin" "${gnu_stat_lock_file}.lock.d"
cat > "${gnu_stat_bin}/stat" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == "-c" && "$2" == "%Y" ]]; then
  printf '1\n'
  exit 0
fi
printf 'unexpected stat args: %s\n' "$*" >&2
exit 1
SH
chmod +x "${gnu_stat_bin}/stat"
set +e
gnu_stat_lock_result=$(
  export PATH="${gnu_stat_bin}:$PATH"
  export VIBEGUARD_LOG_LOCK_ATTEMPTS=1
  export VIBEGUARD_LOG_LOCK_SLEEP_SECONDS=0
  export VIBEGUARD_LOG_LOCK_STALE_SECONDS=2
  source hooks/_lib/log_write.sh
  vg_append_log_line "$gnu_stat_lock_file" '{"gnu_stat_lock":true}'
  printf 'rc=%s' "$?"
)
set -e
assert_contains "$gnu_stat_lock_result" "rc=0" "Shell stale-lock recovery accepts GNU stat mtime"
assert_contains "$(cat "$gnu_stat_lock_file")" '{"gnu_stat_lock":true}' "GNU stat stale-lock recovery writes the log line"
assert_exit_zero "GNU stat stale-lock recovery removes lock directory" test ! -e "${gnu_stat_lock_file}.lock.d"
rm -rf "$gnu_stat_lock_dir"

header "log.sh — runtime append lock contention"

runtime_lock_test_dir="$(mktemp -d)"
runtime_lock_test_file="${runtime_lock_test_dir}/events.jsonl"
runtime_lock_test_stderr="${runtime_lock_test_dir}/stderr"
: > "$runtime_lock_test_file"
mkdir "${runtime_lock_test_file}.lock.d"

set +e
runtime_lock_result=$(
  export VIBEGUARD_LOG_LOCK_ATTEMPTS=1
  export VIBEGUARD_LOG_LOCK_SLEEP_SECONDS=0
  export HOME="${runtime_lock_test_dir}/home"
  export VIBEGUARD_LOG_DIR="${runtime_lock_test_dir}/logs"
  export VIBEGUARD_SESSION_ID="runtime-lock-test"
  source hooks/log.sh
  vg_append_log_line "$runtime_lock_test_file" '{"runtime_locked":true}' 2>"$runtime_lock_test_stderr"
  printf 'rc=%s' "$?"
)
set -e

assert_contains "$runtime_lock_result" "rc=1" "Runtime log append lock contention returns nonzero"
assert_contains "$(cat "$runtime_lock_test_stderr")" "timed out waiting for JSONL append lock" "Runtime log append lock contention reports runtime diagnostic"
assert_contains "$(cat "$runtime_lock_test_stderr")" "runtime JSONL append failed" "Runtime log append lock contention reports hook diagnostic"
assert_not_contains "$(cat "$runtime_lock_test_file")" '{"runtime_locked":true}' "Runtime log append lock contention does not write unlocked"

runtime_errexit_stderr="${runtime_lock_test_dir}/errexit-stderr"
set +e
runtime_errexit_stdout=$(
  VIBEGUARD_LOG_LOCK_ATTEMPTS=1 \
  VIBEGUARD_LOG_LOCK_SLEEP_SECONDS=0 \
  HOME="${runtime_lock_test_dir}/home-errexit" \
  VIBEGUARD_LOG_DIR="${runtime_lock_test_dir}/logs-errexit" \
  VIBEGUARD_SESSION_ID="runtime-lock-errexit-test" \
  bash -c '
    set -e
    source hooks/log.sh
    vg_append_log_line "$1" "$2"
    printf "after-runtime-append"
  ' bash "$runtime_lock_test_file" '{"errexit_locked":true}' 2>"$runtime_errexit_stderr"
)
runtime_errexit_rc=$?
set -e

assert_contains "rc=$runtime_errexit_rc" "rc=1" "Runtime append lock failure exits direct set -e caller"
assert_not_contains "$runtime_errexit_stdout" "after-runtime-append" "Runtime append lock failure stops direct set -e caller"
assert_contains "$(cat "$runtime_errexit_stderr")" "runtime JSONL append failed" "Runtime append lock failure reports hook diagnostic before set -e exit"
assert_not_contains "$(cat "$runtime_lock_test_file")" '{"errexit_locked":true}' "Runtime append set -e failure does not write unlocked"
rm -rf "$runtime_lock_test_dir"

hook_test_finish

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
hook_test_init

file_mode() {
  local file="$1"
  if stat -f '%Lp' "$file" >/dev/null 2>&1; then
    stat -f '%Lp' "$file"
  else
    stat -c '%a' "$file"
  fi
}

header "log.sh — injection protection"
# =========================================================

result=$(
  export VIBEGUARD_LOG_DIR
  source hooks/log.sh
  vg_log "test" "Tool" "pass" "reason with '''triple''' quotes" "detail \$(whoami)"
  cat "$VIBEGUARD_LOG_FILE"
)
assert_contains "$result" "'''triple'''" "Triple quotes are safely logged in reason"
assert_contains "$result" '$(whoami)' "Command substitution is not performed in detail"
assert_not_contains "$result" "$(whoami)" "whoami results do not appear in the log"

# Clear the log and continue testing
> "$VIBEGUARD_LOG_DIR/events.jsonl"

result=$(
  export VIBEGUARD_LOG_DIR
  source hooks/log.sh
  vg_log "test" "Tool" "block" 'reason"; import os; os.system("id"); #' "normal"
  cat "$VIBEGUARD_LOG_FILE"
)
assert_contains "$result" '"decision": "block"' "Python injection payload is safely logged in reason"

# Clear the log and test \r escaping
> "$VIBEGUARD_LOG_DIR/events.jsonl"

result=$(
  export VIBEGUARD_LOG_DIR
  source hooks/log.sh
  reason_with_cr="$(printf 'line1\r\nline2')"
  vg_log "test" "Tool" "pass" "$reason_with_cr" "detail"
  cat "$VIBEGUARD_LOG_FILE"
)
assert_not_contains "$result" $'\r' "Carriage return in reason is escaped and not raw in JSONL"
assert_contains "$result" '\r' "Carriage return is represented as \\r escape sequence in reason"

# Clear the log and test OSC hyperlink sequence (BEL-terminated): \x1b]8;;url\x07
> "$VIBEGUARD_LOG_DIR/events.jsonl"

result=$(
  export VIBEGUARD_LOG_DIR
  source hooks/log.sh
  osc_reason="$(printf '\x1b]8;;https://example.com\x07link text\x1b]8;;\x07')"
  vg_log "test" "Tool" "pass" "$osc_reason" "detail"
  cat "$VIBEGUARD_LOG_FILE"
)
assert_not_contains "$result" $'\x07' "BEL byte from OSC hyperlink sequence is stripped from JSONL"
assert_not_contains "$result" $'\x1b' "ESC byte from OSC hyperlink sequence is stripped from JSONL"

# Clear the log and ensure multibyte truncation stays valid UTF-8
> "$VIBEGUARD_LOG_DIR/events.jsonl"

result=$(
  export VIBEGUARD_LOG_DIR
  source hooks/log.sh
  : > "$VIBEGUARD_LOG_FILE"
  long_detail="$(python3 - <<'PY'
print("查" * 250, end="")
PY
)"
  vg_log "test" "Tool" "pass" "" "$long_detail"
  python3 - "$VIBEGUARD_LOG_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    event = json.loads(next(f))

detail = event["detail"]
print("utf8-ok")
print(f"detail_len={len(detail)}")
PY
)
assert_contains "$result" "utf8-ok" "Multibyte detail truncation keeps log UTF-8 decodable"
assert_contains "$result" "detail_len=200" "Multibyte detail truncation still enforces the 200-char cap"

# Clear the log and ensure obvious secrets are redacted before persistence
> "$VIBEGUARD_LOG_DIR/events.jsonl"

result=$(
  export VIBEGUARD_LOG_DIR
  source hooks/log.sh
  : > "$VIBEGUARD_LOG_FILE"
  vg_log \
    "test" \
    "Bash" \
    "warn" \
    'Authorization: Bearer sk-reason-secret token=reason-token TOKEN=upper-token SECRET=upper-secret PASSWORD=upper-password apiKey=camel-key' \
    'curl -H "Authorization: Bearer sk-detail-secret" https://example.test?api_key=detail-key password=hunter2 --token cli-token --password cli-password TOKEN=detail-token SECRET=detail-secret PASSWORD=detail-password apiKey=detail-camel-key'
  cat "$VIBEGUARD_LOG_FILE"
)
assert_contains "$result" 'Bearer ***REDACTED***' "Bearer tokens are redacted in event logs"
assert_contains "$result" 'api_key=***REDACTED***' "API keys are redacted in event logs"
assert_contains "$result" 'apiKey=***REDACTED***' "CamelCase API keys are redacted in event logs"
assert_contains "$result" 'password=***REDACTED***' "Password assignments are redacted in event logs"
assert_contains "$result" 'TOKEN=***REDACTED***' "Uppercase token assignments are redacted in event logs"
assert_contains "$result" 'SECRET=***REDACTED***' "Uppercase secret assignments are redacted in event logs"
assert_contains "$result" 'PASSWORD=***REDACTED***' "Uppercase password assignments are redacted in event logs"
assert_contains "$result" ' --token ***REDACTED***' "Token flags are redacted in event logs"
assert_contains "$result" ' --password ***REDACTED***' "Password flags are redacted in event logs"
assert_not_contains "$result" "sk-reason-secret" "Reason bearer secret is not persisted"
assert_not_contains "$result" "sk-detail-secret" "Detail bearer secret is not persisted"
assert_not_contains "$result" "detail-key" "API key value is not persisted"
assert_not_contains "$result" "hunter2" "Password value is not persisted"
assert_not_contains "$result" "upper-token" "Uppercase token value is not persisted"
assert_not_contains "$result" "upper-secret" "Uppercase secret value is not persisted"
assert_not_contains "$result" "upper-password" "Uppercase password value is not persisted"
assert_not_contains "$result" "camel-key" "CamelCase API key value is not persisted"
assert_exit_zero "Redacted log remains valid JSON" python3 -c 'import json, sys; json.loads(sys.argv[1])' "$result"

# Existing permissive log files are tightened on append.
mode_result=$(
  export VIBEGUARD_LOG_DIR
  source hooks/log.sh
  : > "$VIBEGUARD_LOG_FILE"
  : > "$VIBEGUARD_LOG_DIR/events.jsonl"
  chmod 755 "$VIBEGUARD_LOG_DIR"
  chmod 644 "$VIBEGUARD_LOG_FILE" "$VIBEGUARD_LOG_DIR/events.jsonl"
  vg_log "test" "Tool" "pass" "permissions" "existing logs"
  printf 'dir=%s primary=%s global=%s' "$(file_mode "$VIBEGUARD_LOG_DIR")" "$(file_mode "$VIBEGUARD_LOG_FILE")" "$(file_mode "$VIBEGUARD_LOG_DIR/events.jsonl")"
)
assert_contains "$mode_result" "dir=700" "Existing log directory permissions are tightened"
assert_contains "$mode_result" "primary=600" "Existing primary log permissions are tightened"
assert_contains "$mode_result" "global=600" "Existing global log permissions are tightened"

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

header "log.sh — runtime mirror append"

mirror_runtime_test_dir="$(mktemp -d)"
mirror_runtime_bin="${mirror_runtime_test_dir}/vibeguard-runtime"
mirror_runtime_count="${mirror_runtime_test_dir}/runtime-calls"
cat > "$mirror_runtime_bin" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

command="${1:-}"
shift || true

case "$command" in
  append-jsonl-mirror)
    printf 'mirror\n' >> "${VIBEGUARD_MIRROR_COUNT:?}"
    primary_file="${1:?append-jsonl-mirror requires a primary path}"
    mirror_file="${2:?append-jsonl-mirror requires a mirror path}"
    line="$(cat)"
    mkdir -p "$(dirname "$primary_file")" "$(dirname "$mirror_file")"
    printf '%s\n' "$line" >> "$primary_file"
    printf '%s\n' "$line" >> "$mirror_file"
    ;;
  append-jsonl)
    printf 'single\n' >> "${VIBEGUARD_MIRROR_COUNT:?}"
    file="${1:?append-jsonl requires a path}"
    line="$(cat)"
    mkdir -p "$(dirname "$file")"
    printf '%s\n' "$line" >> "$file"
    ;;
  *)
    printf 'Unknown command: %s\n' "$command" >&2
    exit 2
    ;;
esac
SH
chmod +x "$mirror_runtime_bin"

mirror_result=$(
  export HOME="${mirror_runtime_test_dir}/home"
  export VIBEGUARD_LOG_DIR="${mirror_runtime_test_dir}/logs"
  export VIBEGUARD_PROJECT_LOG_DIR="${mirror_runtime_test_dir}/project"
  export VIBEGUARD_LOG_FILE="${VIBEGUARD_PROJECT_LOG_DIR}/events.jsonl"
  export VIBEGUARD_SESSION_ID="runtime-mirror-test"
  export VIBEGUARD_RUNTIME="$mirror_runtime_bin"
  export VIBEGUARD_MIRROR_COUNT="$mirror_runtime_count"
  source hooks/log.sh
  vg_log "test" "Tool" "pass" "mirror" "runtime"
  printf 'calls=%s mirror=%s single=%s primary=%s global=%s' \
    "$(wc -l < "$VIBEGUARD_MIRROR_COUNT" | tr -d ' ')" \
    "$(grep -c '^mirror$' "$VIBEGUARD_MIRROR_COUNT" || true)" \
    "$(grep -c '^single$' "$VIBEGUARD_MIRROR_COUNT" || true)" \
    "$(wc -l < "$VIBEGUARD_LOG_FILE" | tr -d ' ')" \
    "$(wc -l < "$VIBEGUARD_LOG_DIR/events.jsonl" | tr -d ' ')"
)

assert_contains "$mirror_result" "calls=1" "Project/global vg_log uses one runtime process for mirror append"
assert_contains "$mirror_result" "mirror=1" "Runtime mirror append command is used"
assert_contains "$mirror_result" "single=0" "Runtime single append is not used for mirrored vg_log"
assert_contains "$mirror_result" "primary=1" "Runtime mirror append writes the primary log"
assert_contains "$mirror_result" "global=1" "Runtime mirror append writes the global log"
rm -rf "$mirror_runtime_test_dir"

header "log.sh — shell mirror preserves global on primary failure"

shell_mirror_lock_dir="$(mktemp -d)"
shell_mirror_primary="${shell_mirror_lock_dir}/project/events.jsonl"
shell_mirror_global="${shell_mirror_lock_dir}/events.jsonl"
shell_mirror_stderr="${shell_mirror_lock_dir}/stderr"
mkdir -p "$(dirname "$shell_mirror_primary")"
mkdir "${shell_mirror_primary}.lock.d"

set +e
shell_mirror_result=$(
  export VIBEGUARD_LOG_LOCK_ATTEMPTS=1
  export VIBEGUARD_LOG_LOCK_SLEEP_SECONDS=0
  source hooks/_lib/log_write.sh
  vg_append_log_line_mirror "$shell_mirror_primary" "$shell_mirror_global" '{"shell_mirror":true}' 2>"$shell_mirror_stderr"
  printf 'rc=%s' "$?"
)
set -e

assert_contains "$shell_mirror_result" "rc=1" "Shell mirror primary lock failure returns nonzero"
assert_contains "$(cat "$shell_mirror_stderr")" "primary event log write failed" "Shell mirror primary failure is visible"
assert_contains "$(cat "$shell_mirror_global")" '{"shell_mirror":true}' "Shell mirror still writes global log after primary failure"
assert_not_contains "$(cat "$shell_mirror_primary" 2>/dev/null || true)" '{"shell_mirror":true}' "Shell mirror primary lock failure does not write unlocked"
rm -rf "$shell_mirror_lock_dir"

header "log.sh — stale runtime fallback"

stale_runtime_test_dir="$(mktemp -d)"
stale_runtime_file="${stale_runtime_test_dir}/events.jsonl"
stale_runtime_stderr="${stale_runtime_test_dir}/stderr"
stale_runtime_bin="${stale_runtime_test_dir}/vibeguard-runtime"
cat > "$stale_runtime_bin" <<'SH'
#!/usr/bin/env bash
printf 'Unknown command: %s\n' "$1" >&2
exit 2
SH
chmod +x "$stale_runtime_bin"

set +e
stale_runtime_result=$(
  _VIBEGUARD_RUNTIME="$stale_runtime_bin"
  source hooks/_lib/log_write.sh
  vg_append_log_line "$stale_runtime_file" '{"stale_runtime":true}' 2>"$stale_runtime_stderr"
  printf 'rc=%s' "$?"
)
set -e

assert_contains "$stale_runtime_result" "rc=0" "Stale runtime without append-jsonl falls back to shell append"
assert_contains "$(cat "$stale_runtime_file")" '{"stale_runtime":true}' "Stale runtime fallback still writes the log line"
assert_not_contains "$(cat "$stale_runtime_stderr")" "runtime JSONL append failed" "Stale runtime fallback does not report runtime append failure"
rm -rf "$stale_runtime_test_dir"

header "log.sh — stale runtime mirror fallback"

stale_mirror_runtime_test_dir="$(mktemp -d)"
stale_mirror_runtime_stderr="${stale_mirror_runtime_test_dir}/stderr"
stale_mirror_runtime_bin="${stale_mirror_runtime_test_dir}/vibeguard-runtime"
cat > "$stale_mirror_runtime_bin" <<'SH'
#!/usr/bin/env bash
printf 'Unknown command: %s\n' "$1" >&2
exit 2
SH
chmod +x "$stale_mirror_runtime_bin"

set +e
stale_mirror_result=$(
  export HOME="${stale_mirror_runtime_test_dir}/home"
  export VIBEGUARD_LOG_DIR="${stale_mirror_runtime_test_dir}/logs"
  export VIBEGUARD_PROJECT_LOG_DIR="${stale_mirror_runtime_test_dir}/project"
  export VIBEGUARD_LOG_FILE="${VIBEGUARD_PROJECT_LOG_DIR}/events.jsonl"
  export VIBEGUARD_SESSION_ID="stale-runtime-mirror-test"
  export VIBEGUARD_RUNTIME="$stale_mirror_runtime_bin"
  source hooks/log.sh
  vg_log "test" "Tool" "pass" "stale mirror" "fallback" 2>"$stale_mirror_runtime_stderr"
  printf 'rc=%s primary=%s global=%s' \
    "$?" \
    "$(wc -l < "$VIBEGUARD_LOG_FILE" | tr -d ' ')" \
    "$(wc -l < "$VIBEGUARD_LOG_DIR/events.jsonl" | tr -d ' ')"
)
set -e

assert_contains "$stale_mirror_result" "rc=0" "Stale runtime without append-jsonl-mirror falls back for mirrored vg_log"
assert_contains "$stale_mirror_result" "primary=1" "Stale runtime mirror fallback writes the primary log"
assert_contains "$stale_mirror_result" "global=1" "Stale runtime mirror fallback writes the global log"
assert_not_contains "$(cat "$stale_mirror_runtime_stderr")" "runtime mirrored JSONL append failed" "Stale runtime mirror fallback does not report runtime mirror failure"
rm -rf "$stale_mirror_runtime_test_dir"

# =========================================================

hook_test_finish

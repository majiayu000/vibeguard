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
  chmod 644 "$VIBEGUARD_LOG_FILE" "$VIBEGUARD_LOG_DIR/events.jsonl"
  vg_log "test" "Tool" "pass" "permissions" "existing logs"
  printf 'primary=%s global=%s' "$(file_mode "$VIBEGUARD_LOG_FILE")" "$(file_mode "$VIBEGUARD_LOG_DIR/events.jsonl")"
)
assert_contains "$mode_result" "primary=600" "Existing primary log permissions are tightened"
assert_contains "$mode_result" "global=600" "Existing global log permissions are tightened"

# =========================================================

hook_test_finish

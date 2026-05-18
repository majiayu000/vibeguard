#!/usr/bin/env bash
# JSON extraction/output helpers for hooks/log.sh.

#Extract specified fields from stdin JSON
# Usage: value=$(echo "$INPUT" | vg_json_field "tool_input.file_path")
vg_json_field() {
  local field_path="$1"
  "$_VIBEGUARD_RUNTIME" json-field "$field_path" 2>/dev/null
}

# Strict field extraction for security-sensitive hooks.
# Unlike vg_json_field, parse errors and missing/null fields are visible and
# return non-zero so callers can fail closed instead of treating them as "".
vg_json_field_strict() {
  local field_path="$1"
  local out err status
  err=$(mktemp)

  if out=$("$_VIBEGUARD_RUNTIME" json-field --strict "$field_path" 2>"$err"); then
    rm -f "$err"
    printf '%s\n' "$out"
    return 0
  else
    status=$?
  fi

  local msg
  msg="$(head -c 200 "$err" 2>/dev/null || true)"
  rm -f "$err"
  vg_log "log.sh" "" "warn" "json-field strict failed: ${msg:-unknown error}" "$field_path"
  return "$status"
}

# Extract two fields from stdin JSON
# Usage: read_result=$(echo "$INPUT" | vg_json_two_fields "tool_input.file_path" "tool_input.content")
#        FILE_PATH=$(echo "$read_result" | head -1)
#        CONTENT=$(echo "$read_result" | tail -n +2)
vg_json_two_fields() {
  local field1="$1"
  local field2="$2"
  "$_VIBEGUARD_RUNTIME" json-two-fields "$field1" "$field2" 2>/dev/null
}

# ---------------------------------------------------------------------------
# vg_json_output — Produce JSON output to stdout with proper escaping.
# Pure bash, no Python subprocess.
#
# Usage:
#   vg_json_output '{"decision":"block","reason":"REASON"}'        # raw JSON
#   vg_json_output decision "block" reason "MESSAGE"               # key-value pairs
#   vg_json_output_kv decision block reason "my reason"            # key-value helper
# ---------------------------------------------------------------------------
vg_json_output_kv() {
  # Accepts key-value pairs: vg_json_output_kv key1 val1 key2 val2 ...
  local json="{"
  local first=true
  while [[ $# -ge 2 ]]; do
    local key="$1" val="$2"; shift 2
    # JSON escape value
    val="${val//\\/\\\\}"
    val="${val//\"/\\\"}"
    val="${val//$'\n'/\\n}"
    val="${val//$'\t'/\\t}"
    if [[ "$first" == "true" ]]; then
      first=false
    else
      json="${json},"
    fi
    json="${json} \"${key}\": \"${val}\""
  done
  json="${json} }"
  printf '%s\n' "$json"
}

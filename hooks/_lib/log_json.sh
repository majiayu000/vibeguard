#!/usr/bin/env bash
# JSON extraction/output helpers for hooks/log.sh.

#Extract specified fields from stdin JSON
# Usage: value=$(echo "$INPUT" | vg_json_field "tool_input.file_path")
vg_json_field() {
  local field_path="$1"
  if [[ -n "$_VG_HELPER" ]]; then
    "$_VG_HELPER" json-field "$field_path" 2>/dev/null || echo ""
  else
    python3 -c "
import json, sys
data = json.load(sys.stdin)
keys = sys.argv[1].split('.')
val = data
for k in keys:
    if isinstance(val, dict): val = val.get(k, '')
    else: val = ''; break
print(val if isinstance(val, str) else '')
" "$field_path" 2>/dev/null || echo ""
  fi
}

# Strict field extraction for security-sensitive hooks.
# Unlike vg_json_field, parse errors and missing/null fields are visible and
# return non-zero so callers can fail closed instead of treating them as "".
vg_json_field_strict() {
  local field_path="$1"
  local out err status
  err=$(mktemp)

  if [[ -n "$_VG_HELPER" && "$_VG_HELPER_JSON_FIELD_STRICT" -eq 1 ]]; then
    if out=$("$_VG_HELPER" json-field --strict "$field_path" 2>"$err"); then
      rm -f "$err"
      printf '%s\n' "$out"
      return 0
    else
      status=$?
    fi
  else
    if out=$(python3 -c "
import json, sys
field_path = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception as exc:
    print(f'json parse failed: {exc}', file=sys.stderr)
    sys.exit(1)
val = data
for key in field_path.split('.'):
    if isinstance(val, dict) and key in val:
        val = val[key]
    else:
        print(f'missing field: {field_path}', file=sys.stderr)
        sys.exit(1)
if val is None:
    print(f'null field: {field_path}', file=sys.stderr)
    sys.exit(1)
if isinstance(val, str):
    print(val)
else:
    print(json.dumps(val, separators=(',', ':')))
" "$field_path" 2>"$err"); then
      rm -f "$err"
      printf '%s\n' "$out"
      return 0
    else
      status=$?
    fi
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
  if [[ -n "$_VG_HELPER" ]]; then
    "$_VG_HELPER" json-two-fields "$field1" "$field2" 2>/dev/null || echo ""
  else
    python3 -c "
import json, sys
data = json.load(sys.stdin)
def get_nested(d, path):
    val = d
    for k in path.split('.'):
        val = val.get(k, '') if isinstance(val, dict) else ''
    return val if isinstance(val, str) else ''
print(get_nested(data, sys.argv[1]))
print(get_nested(data, sys.argv[2]))
" "$field1" "$field2" 2>/dev/null || echo ""
  fi
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

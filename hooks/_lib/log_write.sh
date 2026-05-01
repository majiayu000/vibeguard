#!/usr/bin/env bash
# JSONL log writer for hooks/log.sh.

vg_append_log_line() {
  local file="$1"
  local line="$2"
  local lock_dir="${file}.lock.d"
  local acquired="false"
  local attempts=0
  local status=0

  while [[ "$attempts" -lt 100 ]]; do
    if mkdir "$lock_dir" 2>/dev/null; then
      acquired="true"
      break
    fi
    attempts=$((attempts + 1))
    sleep 0.01 2>/dev/null || true
  done

  if printf '%s\n' "$line" >> "$file"; then
    status=0
  else
    status=$?
  fi

  if [[ "$acquired" == "true" ]]; then
    rmdir "$lock_dir" 2>/dev/null || true
  fi

  return "$status"
}

vg_log() {
  local hook="$1"
  local tool="$2"
  local decision="$3"
  local reason="${4:-}"
  local detail="${5:-}"

  reason="$(vg_redact_sensitive "$reason")"
  detail="$(vg_redact_sensitive "$detail")"

  # Truncate detail to 200 chars after redaction so partial secrets do not leak.
  detail="$(vg_truncate_utf8 "$detail" 200)"

  # Calculation time
  local duration_ms=""
  if [[ -n "$_VG_START_MS" ]]; then
    local end_ms
    if command -v perl &>/dev/null; then
      end_ms=$(perl -MTime::HiRes=time -e 'printf "%.0f", time*1000')
    else
      end_ms=$(date +%s)000
    fi
    duration_ms=$(( end_ms - _VG_START_MS ))
    _VG_START_MS=""
  fi

  mkdir -p "$VIBEGUARD_LOG_DIR" 2>/dev/null
  chmod 700 "$VIBEGUARD_LOG_DIR" 2>/dev/null || true

  # Pure bash JSON serialization (eliminates python3 subprocess)
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  # JSON escape: reason and detail may contain special characters.
  # Strip all C0 control bytes that are NOT JSON-escapable (\b \t \n \f \r).
  # This removes ESC (0x1B) and the orphaned BEL/VT/SO/etc. bytes that OSC/CSI
  # terminal sequences leave behind after ESC is removed (e.g. \x1b]8;;url\x07
  # becomes ]8;;url\x07 with ESC-only stripping; the raw BEL makes JSONL invalid).
  # tr range: 0x00-0x07 (NUL-BEL), 0x0B (VT), 0x0E-0x1F (SO-US incl. ESC), 0x7F (DEL)
  local esc_reason esc_detail
  esc_reason=$(printf '%s' "$reason" | tr -d '\000-\007\013\016-\037\177')
  esc_detail=$(printf '%s' "$detail"  | tr -d '\000-\007\013\016-\037\177')
  esc_reason="${esc_reason//\\/\\\\}" esc_detail="${esc_detail//\\/\\\\}"
  esc_reason="${esc_reason//\"/\\\"}" esc_detail="${esc_detail//\"/\\\"}"
  esc_reason="${esc_reason//$'\n'/\\n}" esc_detail="${esc_detail//$'\n'/\\n}"
  esc_reason="${esc_reason//$'\r'/\\r}" esc_detail="${esc_detail//$'\r'/\\r}"
  esc_reason="${esc_reason//$'\t'/\\t}" esc_detail="${esc_detail//$'\t'/\\t}"
  esc_reason="${esc_reason//$'\b'/\\b}" esc_detail="${esc_detail//$'\b'/\\b}"
  esc_reason="${esc_reason//$'\f'/\\f}" esc_detail="${esc_detail//$'\f'/\\f}"

  local json
  json="{\"ts\": \"${ts}\", \"session\": \"${VIBEGUARD_SESSION_ID}\", \"hook\": \"${hook}\", \"tool\": \"${tool}\", \"decision\": \"${decision}\", \"reason\": \"${esc_reason}\", \"detail\": \"${esc_detail}\""
  [[ -n "$duration_ms" ]] && json="${json}, \"duration_ms\": ${duration_ms}"
  [[ -n "${VIBEGUARD_CLI:-}" ]] && json="${json}, \"cli\": \"${VIBEGUARD_CLI}\""
  [[ -n "${VIBEGUARD_AGENT_TYPE:-}" ]] && json="${json}, \"agent\": \"${VIBEGUARD_AGENT_TYPE}\""
  json="${json}}"

  vg_append_log_line "$VIBEGUARD_LOG_FILE" "$json"
  chmod 600 "$VIBEGUARD_LOG_FILE" 2>/dev/null || true

  # Synchronously write to the global log (for stats.sh aggregation analysis)
  local global_log="${VIBEGUARD_LOG_DIR}/events.jsonl"
  if [[ "$VIBEGUARD_LOG_FILE" != "$global_log" ]]; then
    vg_append_log_line "$global_log" "$json"
    chmod 600 "$global_log" 2>/dev/null || true
  fi
}

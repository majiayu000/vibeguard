#!/usr/bin/env bash
# JSONL log writer for hooks/log.sh.

vg_append_log_line() {
  local file="$1"
  local line="$2"
  local status=0
  local runtime_stderr=""

  if [[ -n "${_VIBEGUARD_RUNTIME:-}" && -x "$_VIBEGUARD_RUNTIME" ]]; then
    if runtime_stderr=$("$_VIBEGUARD_RUNTIME" append-jsonl "$file" <<<"$line" 2>&1); then
      return 0
    else
      status=$?
    fi

    if [[ "$runtime_stderr" == *"Unknown command: append-jsonl"* ]]; then
      _vg_append_log_line_shell "$file" "$line"
      return $?
    fi

    [[ -z "$runtime_stderr" ]] || printf '%s\n' "$runtime_stderr" >&2
    printf 'VIBEGUARD ERROR: runtime JSONL append failed for %s\n' "$file" >&2
    return "$status"
  fi

  _vg_append_log_line_shell "$file" "$line"
}

_vg_log_lock_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true
}

_vg_remove_stale_log_lock() {
  local lock_dir="$1"
  local stale_seconds="${VIBEGUARD_LOG_LOCK_STALE_SECONDS:-600}"
  local now mtime age

  [[ -d "$lock_dir" ]] || return 1
  [[ "$stale_seconds" =~ ^[0-9]+$ ]] || stale_seconds=600
  if [[ "$stale_seconds" -eq 0 ]]; then
    rmdir "$lock_dir" 2>/dev/null
    return $?
  fi
  mtime="$(_vg_log_lock_mtime "$lock_dir")"
  [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
  now="$(date +%s)"
  age=$((now - mtime))
  [[ "$age" -ge "$stale_seconds" ]] || return 1
  rmdir "$lock_dir" 2>/dev/null
}

vg_append_log_line_mirror() {
  local primary_file="$1"
  local mirror_file="$2"
  local line="$3"
  local status=0
  local runtime_stderr=""

  if [[ "$primary_file" == "$mirror_file" ]]; then
    vg_append_log_line "$primary_file" "$line"
    return $?
  fi

  if [[ -n "${_VIBEGUARD_RUNTIME:-}" && -x "$_VIBEGUARD_RUNTIME" ]]; then
    if runtime_stderr=$("$_VIBEGUARD_RUNTIME" append-jsonl-mirror "$primary_file" "$mirror_file" <<<"$line" 2>&1); then
      return 0
    else
      status=$?
    fi

    if [[ "$runtime_stderr" == *"Unknown command: append-jsonl-mirror"* ]]; then
      _vg_append_log_line_mirror_shell "$primary_file" "$mirror_file" "$line"
      return $?
    fi

    [[ -z "$runtime_stderr" ]] || printf '%s\n' "$runtime_stderr" >&2
    printf 'VIBEGUARD ERROR: runtime mirrored JSONL append failed for %s -> %s\n' "$primary_file" "$mirror_file" >&2
    return "$status"
  fi

  _vg_append_log_line_mirror_shell "$primary_file" "$mirror_file" "$line"
}

_vg_append_log_line_shell() {
  local file="$1"
  local line="$2"
  local status=0
  local lock_dir="${file}.lock.d"
  local acquired="false"
  local attempts=0
  local max_attempts="${VIBEGUARD_LOG_LOCK_ATTEMPTS:-100}"
  local sleep_seconds="${VIBEGUARD_LOG_LOCK_SLEEP_SECONDS:-0.01}"

  [[ "$max_attempts" =~ ^[0-9]+$ ]] || max_attempts=100
  [[ "$max_attempts" -gt 0 ]] || max_attempts=1

  while [[ "$attempts" -lt "$max_attempts" ]]; do
    if mkdir "$lock_dir" 2>/dev/null; then
      acquired="true"
      break
    fi
    if _vg_remove_stale_log_lock "$lock_dir"; then
      continue
    fi
    attempts=$((attempts + 1))
    sleep "$sleep_seconds" 2>/dev/null || true
  done

  if [[ "$acquired" != "true" ]]; then
    printf 'VIBEGUARD ERROR: failed to acquire log lock for %s after %s attempts\n' "$file" "$max_attempts" >&2
    return 1
  fi

  if printf '%s\n' "$line" >> "$file"; then
    status=0
  else
    status=$?
    printf 'VIBEGUARD ERROR: failed to append log line to %s\n' "$file" >&2
  fi

  rmdir "$lock_dir" 2>/dev/null || true

  return "$status"
}

_vg_append_log_line_mirror_shell() {
  local primary_file="$1"
  local mirror_file="$2"
  local line="$3"
  local primary_status=0
  local mirror_status=0

  if _vg_append_log_line_shell "$primary_file" "$line"; then
    primary_status=0
  else
    primary_status=$?
    printf 'VIBEGUARD ERROR: primary event log write failed: %s\n' "$primary_file" >&2
  fi

  if _vg_append_log_line_shell "$mirror_file" "$line"; then
    mirror_status=0
  else
    mirror_status=$?
    printf 'VIBEGUARD ERROR: global event log write failed: %s\n' "$mirror_file" >&2
  fi

  if [[ "$primary_status" -ne 0 || "$mirror_status" -ne 0 ]]; then
    return 1
  fi
}

vg_private_log_file() {
  local file="$1"
  [[ -e "$file" ]] || return 0
  chmod 600 "$file" 2>/dev/null || true
}

vg_log_clean_json_text() {
  local text="$1"
  if [[ "$text" =~ ^[A-Za-z0-9_./:\ \(\),-]*$ ]]; then
    printf '%s' "$text"
  else
    printf '%s' "$text" | tr -d '\000-\007\013\016-\037\177'
  fi
}

vg_log_json_escape() {
  local text
  text="$(vg_log_clean_json_text "$1")"
  text="${text//\\/\\\\}"
  text="${text//\"/\\\"}"
  text="${text//$'\n'/\\n}"
  text="${text//$'\r'/\\r}"
  text="${text//$'\t'/\\t}"
  text="${text//$'\b'/\\b}"
  text="${text//$'\f'/\\f}"
  printf '%s' "$text"
}

vg_log_append_string_field() {
  local json="$1"
  local field="$2"
  local value="$3"
  [[ -n "$value" ]] || { printf '%s' "$json"; return 0; }
  printf '%s, "%s": "%s"' "$json" "$field" "$(vg_log_json_escape "$value")"
}

vg_log_triage_rule_id() {
  local text="$1"
  if [[ "${text}" =~ ([A-Z]+[A-Z0-9]*-[0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "${text}" =~ (^|[^A-Z0-9_-])(DEBUG|STUB|CHURN|LARGE-EDIT)([^A-Z0-9_-]|$) ]]; then
    printf '%s' "${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

vg_log_triage_file() {
  if [[ -n "${VIBEGUARD_TRIAGE_FILE:-}" ]]; then
    printf '%s' "${VIBEGUARD_TRIAGE_FILE}"
  elif [[ -n "${VIBEGUARD_REPO_DIR:-}" ]]; then
    printf '%s/data/triage.jsonl' "${VIBEGUARD_REPO_DIR}"
  else
    printf '%s/triage.jsonl' "${VIBEGUARD_LOG_DIR}"
  fi
}

vg_log_triage_projection() {
  local ts="$1" hook="$2" tool="$3" decision="$4" reason="$5" detail="$6"
  local rule_id triage_file triage_json triage_dir
  case "${decision}" in
    warn|block|gate|escalate) ;;
    *) return 0 ;;
  esac
  rule_id="$(vg_log_triage_rule_id "${reason} ${detail}")" || return 0
  triage_file="$(vg_log_triage_file)"
  triage_dir="$(dirname "${triage_file}")"
  mkdir -p "${triage_dir}" 2>/dev/null || {
    printf 'VIBEGUARD ERROR: failed to create triage log directory: %s\n' "${triage_dir}" >&2
    return 0
  }

  triage_json="{\"schema_version\": 1, \"ts\": \"${ts}\", \"rule\": \"$(vg_log_json_escape "${rule_id}")\", \"verdict\": \"unclassified\""
  triage_json="$(vg_log_append_string_field "${triage_json}" "decision" "${decision}")"
  triage_json="$(vg_log_append_string_field "${triage_json}" "hook" "${hook}")"
  triage_json="$(vg_log_append_string_field "${triage_json}" "tool" "${tool}")"
  triage_json="$(vg_log_append_string_field "${triage_json}" "file" "${detail}")"
  triage_json="$(vg_log_append_string_field "${triage_json}" "context" "${reason}")"
  triage_json="$(vg_log_append_string_field "${triage_json}" "session" "${VIBEGUARD_SESSION_ID:-}")"
  triage_json="${triage_json}}"

  vg_private_log_file "${triage_file}"
  if ! vg_append_log_line "${triage_file}" "${triage_json}"; then
    printf 'VIBEGUARD ERROR: triage log write failed: %s\n' "${triage_file}" >&2
  fi
  vg_private_log_file "${triage_file}"
}

vg_log() {
  local hook="$1"
  local tool="$2"
  local decision="$3"
  local reason="${4:-}"
  local detail="${5:-}"

  if [[ "${VIBEGUARD_POLICY_ENFORCEMENT:-}" == "warn" ]]; then
    case "${decision}" in
      block|gate|escalate)
        decision="warn"
        reason="warn-mode advisory: ${reason}"
        ;;
    esac
  fi

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

  if [[ ! -d "$VIBEGUARD_LOG_DIR" ]]; then
    mkdir -p "$VIBEGUARD_LOG_DIR" 2>/dev/null
  fi
  chmod 700 "$VIBEGUARD_LOG_DIR" 2>/dev/null || true

  # Pure bash JSON serialization.
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  # JSON escape: reason and detail may contain special characters.
  # Strip all C0 control bytes that are NOT JSON-escapable (\b \t \n \f \r).
  # This removes ESC (0x1B) and the orphaned BEL/VT/SO/etc. bytes that OSC/CSI
  # terminal sequences leave behind after ESC is removed (e.g. \x1b]8;;url\x07
  # becomes ]8;;url\x07 with ESC-only stripping; the raw BEL makes JSONL invalid).
  # tr range: 0x00-0x07 (NUL-BEL), 0x0B (VT), 0x0E-0x1F (SO-US incl. ESC), 0x7F (DEL)
  local esc_reason esc_detail
  esc_reason=$(vg_log_json_escape "$reason")
  esc_detail=$(vg_log_json_escape "$detail")

  local json
  json="{\"schema_version\": 1, \"ts\": \"${ts}\", \"session\": \"${VIBEGUARD_SESSION_ID}\", \"hook\": \"${hook}\", \"tool\": \"${tool}\", \"decision\": \"${decision}\", \"status\": \"${decision}\", \"reason\": \"${esc_reason}\", \"detail\": \"${esc_detail}\""
  [[ -n "$duration_ms" ]] && json="${json}, \"duration_ms\": ${duration_ms}"
  json="$(vg_log_append_string_field "$json" "cli" "${VIBEGUARD_CLI:-}")"
  json="$(vg_log_append_string_field "$json" "agent" "${VIBEGUARD_AGENT_TYPE:-}")"
  json="$(vg_log_append_string_field "$json" "client" "${VIBEGUARD_CLIENT:-}")"
  json="$(vg_log_append_string_field "$json" "client_variant" "${VIBEGUARD_CLIENT_VARIANT:-}")"
  json="$(vg_log_append_string_field "$json" "wrapper" "${VIBEGUARD_WRAPPER:-}")"
  json="$(vg_log_append_string_field "$json" "source_config" "${VIBEGUARD_SOURCE_CONFIG:-}")"
  json="$(vg_log_append_string_field "$json" "hook_protocol_version" "${VIBEGUARD_HOOK_PROTOCOL_VERSION:-}")"
  json="$(vg_log_append_string_field "$json" "caller_evidence" "${VIBEGUARD_CALLER_EVIDENCE:-}")"
  json="${json}}"

  # Synchronously mirror project logs into the global log for stats aggregation.
  local global_log="${VIBEGUARD_LOG_DIR}/events.jsonl"
  vg_private_log_file "$VIBEGUARD_LOG_FILE"
  vg_private_log_file "$global_log"
  if [[ "$VIBEGUARD_LOG_FILE" != "$global_log" ]]; then
    if ! vg_append_log_line_mirror "$VIBEGUARD_LOG_FILE" "$global_log" "$json"; then
      printf 'VIBEGUARD ERROR: mirrored event log write failed: %s -> %s\n' "$VIBEGUARD_LOG_FILE" "$global_log" >&2
    fi
  else
    if ! vg_append_log_line "$VIBEGUARD_LOG_FILE" "$json"; then
      printf 'VIBEGUARD ERROR: primary event log write failed: %s\n' "$VIBEGUARD_LOG_FILE" >&2
    fi
  fi
  vg_private_log_file "$VIBEGUARD_LOG_FILE"
  vg_private_log_file "$global_log"
  vg_log_triage_projection "${ts}" "${hook}" "${tool}" "${decision}" "${reason}" "${detail}"
}

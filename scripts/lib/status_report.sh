#!/usr/bin/env bash
# VibeGuard status reporter — shared library for `setup.sh --check`.
#
# Purpose
#   Turn the existing free-form `[OK]/[INFO]/[WARN]/[FAIL]/[BROKEN]/[MISSING]`
#   lines into a structured, summarized, exit-code-aware health report
#   without rewriting every call site (lib.sh, targets/*.sh, etc.).
#
# How it works
#   The legacy probes already print one status line per check, prefixed
#   with `[LEVEL]`. We capture the whole stdout stream of `--check` once,
#   tee it to the user, and post-process the captured copy to compute
#   counts, problem rows, JSON, and the exit code. Zero call-site changes.
#
# Public API (all exit codes are 0 unless documented)
#   status_init <buffer_file>             — initialize a fresh tally
#   status_record_buffer <buffer_file>    — replay buffer into counters
#   status_print_summary [--quiet]        — rollup table on stdout
#   status_emit_json                      — single-line JSON to stdout
#   status_exit_code                      — echo 0|1|2
#
# Exit-code policy
#   0 — no [WARN]/[FAIL]/[BROKEN]/[MISSING]
#   1 — only [WARN] (degraded but functional)
#   2 — at least one [FAIL]/[BROKEN]/required [MISSING] (broken — needs repair)
#
# Per the VibeGuard "no silent degradation" rule (U-29), [INFO] is treated
# as neutral and never affects exit code or verdict.

if [[ -n "${_VG_STATUS_REPORT_LOADED:-}" ]]; then
  return 0
fi
_VG_STATUS_REPORT_LOADED=1

_VG_STATUS_BUFFER=""
_VG_STATUS_OK=0
_VG_STATUS_INFO=0
_VG_STATUS_WARN=0
_VG_STATUS_FAIL=0
_VG_STATUS_BROKEN=0
_VG_STATUS_MISSING=0

# status_init <buffer_path>
#   Reset counters and remember which file holds the captured stdout.
#   Caller is responsible for writing into <buffer_path>; this library
#   only reads it.
status_init() {
  _VG_STATUS_BUFFER="${1:-}"
  _VG_STATUS_OK=0
  _VG_STATUS_INFO=0
  _VG_STATUS_WARN=0
  _VG_STATUS_FAIL=0
  _VG_STATUS_BROKEN=0
  _VG_STATUS_MISSING=0
}

# status_classify_line <line>
#   Echo the level (OK|INFO|WARN|FAIL|BROKEN|MISSING) or empty string.
#   Strips ANSI color codes before matching. Pure function — no globals.
status_plain_line() {
  local line="$1"
  local plain="$line"
  local esc=$'\033'
  local ansi_re="${esc}\\[[0-9;]*[A-Za-z]"
  while [[ "$plain" =~ $ansi_re ]]; do
    plain="${plain/${BASH_REMATCH[0]}/}"
  done
  printf '%s' "$plain"
}

status_classify_line() {
  local line="$1"
  # Drop ANSI SGR escapes inline so we do not depend on `sed` here.
  # Pattern matches ESC [ ... letter and removes it via parameter expansion.
  local plain
  plain="$(status_plain_line "$line")"
  case "$plain" in
    "[OK]"*)      printf 'OK' ;;
    "[INFO]"*)    printf 'INFO' ;;
    "[WARN]"*)    printf 'WARN' ;;
    "[FAIL]"*)    printf 'FAIL' ;;
    "[BROKEN]"*)  printf 'BROKEN' ;;
    "[MISSING]"*) printf 'MISSING' ;;
    *)             printf '' ;;
  esac
}

status_optional_missing_line() {
  local line="$1"
  local plain
  plain="$(status_plain_line "$line")"
  case "$plain" in
    *"ast-grep not installed"*|\
    *"agents not in ~/.claude/agents/"*|\
    *"context profiles not in ~/.claude/context-profiles/"*|\
    *" skill not in ~/.codex/skills/"*|\
    *"VibeGuard hooks not fully configured in ~/.codex/hooks.json"*|\
    *"Codex hooks.json not installed"*|\
    *"Codex hook wrapper not installed"*|\
    *"Codex hook wrapper: "*|\
    *"hooks feature not enabled"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

status_required_missing_count() {
  local required=0 line level
  [[ -n "${_VG_STATUS_BUFFER}" && -f "${_VG_STATUS_BUFFER}" ]] || { printf '0\n'; return 0; }
  while IFS= read -r line; do
    level="$(status_classify_line "$line")"
    if [[ "$level" == "MISSING" ]] && ! status_optional_missing_line "$line"; then
      required=$((required + 1))
    fi
  done < "${_VG_STATUS_BUFFER}"
  printf '%d\n' "$required"
}

# status_record_buffer
#   Read the captured stdout buffer and update counters. Idempotent —
#   recounts from scratch on every call.
status_record_buffer() {
  _VG_STATUS_OK=0
  _VG_STATUS_INFO=0
  _VG_STATUS_WARN=0
  _VG_STATUS_FAIL=0
  _VG_STATUS_BROKEN=0
  _VG_STATUS_MISSING=0
  [[ -n "${_VG_STATUS_BUFFER}" && -f "${_VG_STATUS_BUFFER}" ]] || return 0
  local line level
  while IFS= read -r line; do
    level="$(status_classify_line "$line")"
    case "$level" in
      OK)      _VG_STATUS_OK=$((_VG_STATUS_OK + 1)) ;;
      INFO)    _VG_STATUS_INFO=$((_VG_STATUS_INFO + 1)) ;;
      WARN)    _VG_STATUS_WARN=$((_VG_STATUS_WARN + 1)) ;;
      FAIL)    _VG_STATUS_FAIL=$((_VG_STATUS_FAIL + 1)) ;;
      BROKEN)  _VG_STATUS_BROKEN=$((_VG_STATUS_BROKEN + 1)) ;;
      MISSING) _VG_STATUS_MISSING=$((_VG_STATUS_MISSING + 1)) ;;
    esac
  done < "${_VG_STATUS_BUFFER}"
}

# status_filter_problems
#   Emit only [WARN]/[FAIL]/[BROKEN]/[MISSING] rows from the buffer, in
#   their original captured form (color preserved).
status_filter_problems() {
  [[ -n "${_VG_STATUS_BUFFER}" && -f "${_VG_STATUS_BUFFER}" ]] || return 0
  local line level
  while IFS= read -r line; do
    level="$(status_classify_line "$line")"
    case "$level" in
      WARN|FAIL|BROKEN|MISSING) printf '%s\n' "$line" ;;
    esac
  done < "${_VG_STATUS_BUFFER}"
}

# status_print_summary [--quiet]
#   Print the summary block. With --quiet, prepend a "Problems" section
#   that re-prints only the rows the user actually has to act on.
status_print_summary() {
  local quiet=0
  [[ "${1:-}" == "--quiet" ]] && quiet=1
  local total_problems=$((_VG_STATUS_FAIL + _VG_STATUS_BROKEN + _VG_STATUS_MISSING))
  local total_warnings=${_VG_STATUS_WARN}

  if [[ "${quiet}" -eq 1 ]] && (( total_problems + total_warnings > 0 )); then
    printf '\nProblems\n'
    printf -- '------------------------------\n'
    status_filter_problems
  fi

  printf '\nSummary\n'
  printf -- '------------------------------\n'
  printf '  OK      : %d\n' "${_VG_STATUS_OK}"
  printf '  INFO    : %d\n' "${_VG_STATUS_INFO}"
  printf '  WARN    : %d\n' "${_VG_STATUS_WARN}"
  printf '  FAIL    : %d\n' "${_VG_STATUS_FAIL}"
  printf '  BROKEN  : %d\n' "${_VG_STATUS_BROKEN}"
  printf '  MISSING : %d\n' "${_VG_STATUS_MISSING}"

  printf '\nVerdict : '
  if (( total_problems > 0 )); then
    printf '\033[31mBROKEN\033[0m (run: bash setup.sh)\n'
  elif (( total_warnings > 0 )); then
    printf '\033[33mDEGRADED\033[0m (functional, optional features missing)\n'
  else
    printf '\033[32mHEALTHY\033[0m\n'
  fi
}

# status_emit_json
#   Emit a stable JSON document with counts, verdict, and the full event
#   list. Designed for CI consumers and the /vibeguard:check skill.
status_emit_json() {
  local total_problems=$((_VG_STATUS_FAIL + _VG_STATUS_BROKEN + _VG_STATUS_MISSING))
  local verdict
  if (( total_problems > 0 )); then
    verdict="broken"
  elif (( _VG_STATUS_WARN > 0 )); then
    verdict="degraded"
  else
    verdict="healthy"
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    # Conservative fallback. We escape backslash, double-quote, and control
    # characters so the result is valid JSON without python3.
    printf '{"schema_version":1,"verdict":"%s","counts":{"ok":%d,"info":%d,"warn":%d,"fail":%d,"broken":%d,"missing":%d},"events":[' \
      "$verdict" "$_VG_STATUS_OK" "$_VG_STATUS_INFO" "$_VG_STATUS_WARN" "$_VG_STATUS_FAIL" "$_VG_STATUS_BROKEN" "$_VG_STATUS_MISSING"
    local first=1 line level message esc
    if [[ -n "${_VG_STATUS_BUFFER}" && -f "${_VG_STATUS_BUFFER}" ]]; then
      while IFS= read -r line; do
        level="$(status_classify_line "$line")"
        [[ -z "$level" ]] && continue
        message="$(status_plain_line "$line")"
        esc="${message//\\/\\\\}"
        esc="${esc//\"/\\\"}"
        esc="${esc//	/ }"
        if [[ $first -eq 1 ]]; then
          first=0
        else
          printf ','
        fi
        printf '{"level":"%s","message":"%s"}' "$level" "$esc"
      done < "${_VG_STATUS_BUFFER}"
    fi
    printf ']}\n'
    return 0
  fi

  VG_VERDICT="$verdict" \
  VG_OK="$_VG_STATUS_OK" VG_INFO="$_VG_STATUS_INFO" VG_WARN="$_VG_STATUS_WARN" \
  VG_FAIL="$_VG_STATUS_FAIL" VG_BROKEN="$_VG_STATUS_BROKEN" VG_MISSING="$_VG_STATUS_MISSING" \
  VG_BUFFER="${_VG_STATUS_BUFFER:-}" \
  python3 - <<'PY'
import json, os, re, sys

ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
LEVELS = ("OK", "INFO", "WARN", "FAIL", "BROKEN", "MISSING")

def classify(line: str):
    plain = ANSI.sub("", line)
    for level in LEVELS:
        if plain.startswith(f"[{level}]"):
            return level, plain
    return None, plain

events = []
buf = os.environ.get("VG_BUFFER", "")
if buf and os.path.isfile(buf):
    with open(buf, "r", encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            level, plain = classify(line)
            if level is None:
                continue
            events.append({"level": level, "message": plain})

doc = {
    "schema_version": 1,
    "verdict": os.environ["VG_VERDICT"],
    "counts": {
        "ok": int(os.environ["VG_OK"]),
        "info": int(os.environ["VG_INFO"]),
        "warn": int(os.environ["VG_WARN"]),
        "fail": int(os.environ["VG_FAIL"]),
        "broken": int(os.environ["VG_BROKEN"]),
        "missing": int(os.environ["VG_MISSING"]),
    },
    "events": events,
}
json.dump(doc, sys.stdout, ensure_ascii=False)
sys.stdout.write("\n")
PY
}

# status_exit_code — echo 0|1|2 per the policy at top of file.
status_exit_code() {
  local total_problems=$((_VG_STATUS_FAIL + _VG_STATUS_BROKEN + _VG_STATUS_MISSING))
  if (( total_problems > 0 )); then
    printf '2\n'
  elif (( _VG_STATUS_WARN > 0 )); then
    printf '1\n'
  else
    printf '0\n'
  fi
}

# status_install_exit_code — echo 0|2 for install final verification.
# WARN rows are allowed here because optional integrations can be degraded
# without making the freshly written required runtime unusable.
status_install_exit_code() {
  local required_missing
  required_missing="$(status_required_missing_count)"
  local total_problems=$((_VG_STATUS_FAIL + _VG_STATUS_BROKEN + required_missing))
  if (( total_problems > 0 )); then
    printf '2\n'
  else
    printf '0\n'
  fi
}

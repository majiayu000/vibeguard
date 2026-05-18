#!/usr/bin/env bash
# Stateless content detectors for post-edit-guard.sh.

vg_post_edit_detect_rust() {
  [[ "$FILE_PATH" == *.rs ]] || return 0
  case "$FILE_PATH" in
    */tests/*|*_test.rs|*/test_*) return 0 ;;
  esac

  local filtered unsafe_count safe_count real_count silent_count
  if [[ "$NEW_STRING" == *".unwrap("* || "$NEW_STRING" == *".expect("* ]]; then
    filtered=$(printf '%s\n' "$NEW_STRING" | vg_filter_suppressed "RS-03")
    unsafe_count=$(printf '%s\n' "$filtered" | grep -cE '\.(unwrap|expect)\(' 2>/dev/null || true)
    safe_count=$(printf '%s\n' "$filtered" | grep -cE '\.(unwrap_or|unwrap_or_else|unwrap_or_default)\(' 2>/dev/null || true)
    real_count=$((unsafe_count - safe_count))
    if [[ $real_count -gt 0 ]]; then
      vg_post_edit_append_warning "[RS-03] [review] [this-edit] OBSERVATION: ${real_count} new unwrap()/expect() call(s) added
SCOPE: this-edit only — do not propagate changes beyond this edit, add error types, or change signatures
ACTION: REVIEW"
    fi
  fi

  if [[ "$NEW_STRING" =~ (^|[[:space:]])let[[:space:]]+_[[:space:]]*= ]]; then
    silent_count=$(printf '%s\n' "$NEW_STRING" | vg_filter_suppressed "RS-10" | grep -cE '^\s*let\s+_\s*=' 2>/dev/null || true)
    silent_count="${silent_count:-0}"
    if [[ $silent_count -gt 0 ]]; then
      vg_post_edit_append_warning "[RS-10] [review] [this-edit] OBSERVATION: ${silent_count} new let _ = silent discard(s) added
SCOPE: this-edit only — do not refactor calling code or add new error types
ACTION: REVIEW"
    fi
  fi
}

vg_post_edit_detect_ts_console() {
  case "$FILE_PATH" in
    *.ts|*.tsx|*.js|*.jsx) ;;
    *) return 0 ;;
  esac
  case "$FILE_PATH" in
    */tests/*|*_test.*|*.test.*|*.spec.*) return 0 ;;
    */debug.*|*/debug/*|*logger*|*logging*) return 0 ;;
  esac

  local pkg_dir is_cli console_count file_console_total
  pkg_dir=$(dirname "$FILE_PATH")
  is_cli=false
  while [[ "$pkg_dir" != "/" && "$pkg_dir" != "." ]]; do
    if [[ -f "$pkg_dir/package.json" ]]; then
      grep -qE '"bin"' "$pkg_dir/package.json" 2>/dev/null && is_cli=true
      grep -qE '"[^"]*":\s*"[^"]*cli[^"]*"' "$pkg_dir/package.json" 2>/dev/null && is_cli=true
    fi
    ls "$pkg_dir/src/cli."* "$pkg_dir/cli."* 2>/dev/null | grep -q . && is_cli=true
    [[ "$is_cli" == true ]] && break
    pkg_dir=$(dirname "$pkg_dir")
  done

  if [[ "$is_cli" == true ]]; then
    return 0
  fi
  if [[ -f "$FILE_PATH" ]] && grep -qE '(StdioServerTransport|new Server\(|McpServer)' "$FILE_PATH" 2>/dev/null; then
    return 0
  fi

  console_count=$(printf '%s\n' "$NEW_STRING" | vg_filter_suppressed "DEBUG" | grep -cE '\bconsole\.(log|warn|error)\(' 2>/dev/null || true)
  console_count="${console_count:-0}"
  [[ $console_count -gt 0 ]] || return 0

  file_console_total=0
  if [[ -f "$FILE_PATH" ]]; then
    file_console_total=$(grep -cE '\bconsole\.(log|warn|error)\(' "$FILE_PATH" 2>/dev/null || true)
  fi
  file_console_total="${file_console_total:-0}"

  if [[ $file_console_total -ge 10 ]]; then
    vg_post_edit_append_warning "[DEBUG] [review] [this-file] OBSERVATION: file has ${file_console_total} console residuals and new ones are being added
FIX: Remove this console.log/warn/error call; keep only if this is intentional debug output
DO NOT: Create logger modules, modify other files, or fix console usage outside this file"
  else
    vg_post_edit_append_warning "[DEBUG] [review] [this-edit] OBSERVATION: ${console_count} new console.log/warn/error call(s) added
FIX: Remove this console.log/warn/error call; keep only if this is a CLI project (check bin field in package.json)
DO NOT: Create new logger modules, modify other files, or fix console usage outside this edit"
  fi
}

vg_post_edit_detect_python_print() {
  [[ "$FILE_PATH" == *.py ]] || return 0
  case "$FILE_PATH" in
    */tests/*|*test_*|*_test.py) return 0 ;;
  esac

  local print_count
  print_count=$(printf '%s\n' "$NEW_STRING" | vg_filter_suppressed "DEBUG" | grep -cE '^\s*print\(' 2>/dev/null || true)
  print_count="${print_count:-0}"
  if [[ $print_count -gt 0 ]]; then
    vg_post_edit_append_warning "[DEBUG] [review] [this-edit] OBSERVATION: ${print_count} new print() statement(s) added
FIX: Remove this print() call, or replace with logging.getLogger(__name__).debug() for permanent logging
DO NOT: Modify logging configuration or other files"
  fi
}

vg_post_edit_detect_hardcoded_db_path() {
  [[ "$NEW_STRING" == *".db\""* || "$NEW_STRING" == *".sqlite\""* ]] || return 0
  printf '%s\n' "$NEW_STRING" | vg_filter_suppressed "U-11" | grep -qE '"[^"]*\.(db|sqlite)"' 2>/dev/null || return 0
  case "$FILE_PATH" in
    */tests/*|*_test.*|*.test.*|*.spec.*) return 0 ;;
  esac

  vg_post_edit_append_warning "[U-11] [review] [this-line] OBSERVATION: hardcoded database path (.db/.sqlite) detected
FIX: Extract to a shared default_db_path() function in core layer; use env var APP_DB_PATH for override
DO NOT: Refactor path functions, move code to another file, or change other hardcoded paths"
}

vg_post_edit_detect_go() {
  [[ "$FILE_PATH" == *.go ]] || return 0
  case "$FILE_PATH" in
    *_test.go|*/vendor/*) return 0 ;;
  esac

  local err_discard defer_loop
  err_discard=$(printf '%s\n' "$NEW_STRING" | vg_filter_suppressed "GO-01" | grep -E '^\s*_\s*(,\s*_)?\s*[:=]+' 2>/dev/null \
    | grep -cvE '(for\s+.*range|,\s*(ok|found|exists)\s*:?=)' 2>/dev/null || true)
  err_discard="${err_discard:-0}"
  if [[ $err_discard -gt 0 ]]; then
    vg_post_edit_append_warning "[GO-01] [auto-fix] [this-line] OBSERVATION: ${err_discard} new error discard(s) (\"_ = ...\") added
FIX: Replace _ = fn() with err := fn(); if err != nil { return fmt.Errorf(\"context: %w\", err) }
DO NOT: Modify function signatures or upstream callers"
  fi

  defer_loop=$(printf '%s\n' "$NEW_STRING" | vg_filter_suppressed "GO-08" | awk '/^\s*for\s/ {in_loop=1} /^\s*defer\s/ && in_loop {count++} /^\s*\}/ {in_loop=0} END {print count+0}' 2>/dev/null || true)
  defer_loop="${defer_loop:-0}"
  if [[ $defer_loop -gt 0 ]]; then
    vg_post_edit_append_warning "[GO-08] [review] [this-edit] OBSERVATION: defer inside a loop detected, may cause resource leak
FIX: Extract the loop body containing defer into a separate function
DO NOT: Extract to a separate file or refactor loop logic beyond the current edit"
  fi
}

vg_post_edit_detect_stubs() {
  local stub_warnings
  stub_warnings=$(vg_detect_stubs "$FILE_PATH" "$NEW_STRING" --filter-suppressed)
  vg_post_edit_append_warning "$stub_warnings"
}

vg_post_edit_detect_large_edit() {
  local diff_lines
  if [[ -z "$NEW_STRING" ]]; then
    diff_lines=0
  else
    local without_newlines="${NEW_STRING//$'\n'/}"
    diff_lines=$(( ${#NEW_STRING} - ${#without_newlines} + 1 ))
  fi
  if [[ $diff_lines -gt 200 ]]; then
    vg_post_edit_append_warning "[LARGE-EDIT] [info] [this-edit] OBSERVATION: single edit contains ${diff_lines} lines, exceeding 200-line threshold
FIX: Verify the edit content is correct and intentional
DO NOT: Take any action — this is informational only"
  fi
}

vg_post_edit_detect_u16_size() {
  case "$FILE_PATH" in
    *.rs|*.ts|*.tsx|*.js|*.jsx|*.py|*.go) ;;
    *) return 0 ;;
  esac
  case "$FILE_PATH" in
    */tests/*|*_test.*|*.test.*|*.spec.*|*_test.rs|*/test_*) return 0 ;;
  esac
  [[ -f "$FILE_PATH" ]] || return 0

  local total limit dir exempt base_limit
  # Base U-16 limit resolved from env var > ~/.vibeguard/config.json > built-in 800.
  base_limit=$(vg_config_get_int VG_U16_LIMIT u16.limit 800)
  total=$(wc -l < "$FILE_PATH" | tr -d ' ')
  [[ "$total" -gt "$base_limit" ]] || return 0

  limit="$base_limit"
  dir="$FILE_PATH"
  while [[ "$dir" != "/" ]]; do
    dir=$(dirname "$dir")
    [[ -d "$dir/.git" ]] && break
  done
  if [[ "$dir" != "/" && -f "$dir/CLAUDE.md" ]]; then
    exempt=$(VG_CLAUDE_MD="$dir/CLAUDE.md" VG_FILE_PATH="$FILE_PATH" python3 -c '
import os, re
from pathlib import PurePath
claude_md = os.environ["VG_CLAUDE_MD"]
file_path = os.environ["VG_FILE_PATH"]
limit = 0
try:
    with open(claude_md) as f:
        for line in f:
            if "U-16 exempt" not in line:
                continue
            for pair in re.finditer(r"`([^`]+)`\s*→\s*(\d+)", line):
                pattern, lim = pair.group(1), int(pair.group(2))
                try:
                    if PurePath(file_path).match(pattern):
                        limit = max(limit, lim)
                except (ValueError, TypeError):
                    continue
except FileNotFoundError:
    pass
print(limit)
' 2>/dev/null | tr -d '[:space:]' || echo "0")
    exempt="${exempt:-0}"
    if [[ "$exempt" -gt 0 ]]; then
      limit="$exempt"
    fi
  fi

  if [[ "$total" -gt "$limit" ]]; then
    vg_post_edit_append_warning "[U-16] [review] [this-file] OBSERVATION: file has ${total} lines, exceeding ${limit}-line limit
FIX: Split into focused submodules by responsibility; plan as a separate task
DO NOT: Start splitting now — finish the current task first, then refactor"
  fi
}

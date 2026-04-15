#!/usr/bin/env bash
# Shared Anti-Stub detection for post-edit-guard.sh and post-write-guard.sh
#
# Usage:
#   source "$(dirname "$0")/_lib/stub_detect.sh"
#   STUB_WARNINGS=$(vg_detect_stubs "$FILE_PATH" "$CONTENT" [--filter-suppressed])
#
# When --filter-suppressed is passed, content is piped through vg_filter_suppressed
# (requires vg_filter_suppressed to be defined, i.e. post-edit-guard context).
# Without the flag, raw grep is used (post-write-guard context where suppression
# comments are not yet meaningful).

vg_detect_stubs() {
  local file_path="$1"
  local content="$2"
  local use_filter="${3:-}"
  local stub_count=0
  local lang_desc=""

  _stub_grep() {
    local pattern="$1"
    if [[ "$use_filter" == "--filter-suppressed" ]] && declare -f vg_filter_suppressed &>/dev/null; then
      echo "$content" | vg_filter_suppressed "STUB" | grep -cE "$pattern" 2>/dev/null || true
    else
      echo "$content" | grep -cE "$pattern" 2>/dev/null || true
    fi
  }

  case "$file_path" in
    *.rs)
      stub_count=$(_stub_grep '^\s*(todo!\(|unimplemented!\(|panic!\("not implemented)')
      lang_desc="todo!/unimplemented!"
      ;;
    *.ts|*.tsx|*.js|*.jsx)
      stub_count=$(_stub_grep '^\s*(throw new Error\(.*(not implemented|TODO|FIXME)|// TODO|// FIXME|return null.*// stub)')
      lang_desc="throw not implemented / TODO"
      ;;
    *.py)
      stub_count=$(_stub_grep '^\s*(pass\s*$|pass\s*#|raise NotImplementedError|# TODO|# FIXME)')
      lang_desc="pass/NotImplementedError/TODO"
      ;;
    *.go)
      stub_count=$(_stub_grep '^\s*(panic\("not implemented|// TODO|// FIXME)')
      lang_desc="panic not implemented / TODO"
      ;;
    *)
      echo ""
      return
      ;;
  esac

  if [[ "${stub_count:-0}" -gt 0 ]]; then
    local context="added"
    [[ "$use_filter" != "--filter-suppressed" ]] && context="found in new file"
    echo "[STUB] [review] [this-edit] OBSERVATION: ${stub_count} stub placeholder(s) ${context} (${lang_desc})
FIX: Replace with real implementation in this task, or add a DEFER comment explaining why
DO NOT: Add DEFER markers to stubs in other files"
  else
    echo ""
  fi
}

#!/usr/bin/env bash
# VibeGuard Stop Hook — Verify access control before completion
#
# Check if there are any uncommitted source code changes at the end of the AI session.
# There are uncommitted changes → exit 0 (log only; exit 2 will trigger an infinite loop in the Stop context)
# No changes or non-git repository → exit 0 (pass silently)

set -euo pipefail

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/circuit-breaker.sh"
vg_start_timer

# CI guard: skip interactive hooks in CI environments
vg_is_ci && exit 0

# Read stdin once (Stop hook receives JSON input)
INPUT=$(cat 2>/dev/null || true)

# stop_hook_active: platform sets this when a Stop hook triggered another Stop hook.
# Checking it breaks the feedback → Stop hook → feedback → Stop hook infinite loop.
vg_stop_hook_active "$INPUT" && exit 0

# Not in git repository → skip
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  exit 0
fi

# Check if there are any uncommitted source code changes (staged + unstaged)
changed_source_files=""
while IFS= read -r file; do
  if [[ -n "$file" ]] && vg_is_source_file "$file"; then
    changed_source_files="${changed_source_files}${file}"$'\n'
  fi
done < <(git diff --name-only HEAD 2>/dev/null || git diff --name-only --cached 2>/dev/null)

# Remove duplicates
if [[ -n "$changed_source_files" ]]; then
  changed_source_files=$(echo "$changed_source_files" | sort -u)
  count=$(echo "$changed_source_files" | grep -c . || true)

  vg_log "stop-guard" "Stop" "gate" "uncommitted source changes: ${count} files" "$(echo "$changed_source_files" | head -5 | tr '\n' ' ')"

  # exit 0: log only, do not block — Claude cannot commit in Stop context,
  # so exit 2 here causes an infinite loop (feedback → response → stop hooks → repeat).
  # See GitHub issues #3573, #10205.
  exit 0
fi

vg_log "stop-guard" "Stop" "pass" "" ""
exit 0

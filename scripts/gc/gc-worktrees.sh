#!/usr/bin/env bash
# VibeGuard GC — Worktree Cleanup
#
# Scan .vibeguard/worktrees/ and delete worktrees that have been inactive for more than the specified number of days.
# Worktrees with unmerged changes will only be warned but not deleted.
#
# Usage:
# bash gc-worktrees.sh # Default 7 days
# bash gc-worktrees.sh --days 14 # 14 days
# bash gc-worktrees.sh --dry-run # Report only

set -euo pipefail

green() { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
red() { printf '\033[31m%s\033[0m\n' "$1"; }

MAX_DAYS=7
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days) MAX_DAYS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) shift ;;
  esac
done

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  red "Error: Not in git repository"
  exit 1
fi

REPO_ROOT=$(git rev-parse --show-toplevel)
WORKTREE_BASE="${REPO_ROOT}/.vibeguard/worktrees"

if [[ ! -d "$WORKTREE_BASE" ]]; then
  green "No worktree directory, skip"
  exit 0
fi

NOW=$(date +%s)
CLEANED=0
WARNED=0

for wt_dir in "${WORKTREE_BASE}"/*/; do
  [[ -d "$wt_dir" ]] || continue
  NAME=$(basename "$wt_dir")

  # Get the latest modification time (get the latest file in the .git file or directory)
  if [[ -f "${wt_dir}.git" ]]; then
    LAST_MOD=$(stat -f %m "${wt_dir}.git" 2>/dev/null || stat -c %Y "${wt_dir}.git" 2>/dev/null || echo "$NOW")
  else
    LAST_MOD=$(find "$wt_dir" -maxdepth 2 -type f -newer "$wt_dir" -print -quit 2>/dev/null | head -1)
    if [[ -z "$LAST_MOD" ]]; then
      LAST_MOD=$(stat -f %m "$wt_dir" 2>/dev/null || stat -c %Y "$wt_dir" 2>/dev/null || echo "$NOW")
    else
      LAST_MOD=$(stat -f %m "$LAST_MOD" 2>/dev/null || stat -c %Y "$LAST_MOD" 2>/dev/null || echo "$NOW")
    fi
  fi

  DAYS_OLD=$(( (NOW - LAST_MOD) / 86400 ))

  if [[ "$DAYS_OLD" -lt "$MAX_DAYS" ]]; then
    echo "${NAME}: ${DAYS_OLD} days — reserved"
    continue
  fi

  # Check for unmerged changes
  HAS_CHANGES=false
  if git -C "$wt_dir" status --porcelain 2>/dev/null | grep -q .; then
    HAS_CHANGES=true
  fi

  BRANCH="vg/${NAME}"
  UNMERGED=false
  if git branch --no-merged 2>/dev/null | grep -q "$BRANCH"; then
    UNMERGED=true
  fi

  if [[ "$HAS_CHANGES" == "true" ]] || [[ "$UNMERGED" == "true" ]]; then
    yellow " ${NAME}: ${DAYS_OLD} days — unmerged changes, skip"
    [[ "$HAS_CHANGES" == "true" ]] && yellow "Uncommitted changes"
    [[ "$UNMERGED" == "true" ]] && yellow "Branch ${BRANCH} is not merged"
    WARNED=$((WARNED + 1))
    continue
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    yellow " [DRY-RUN] ${NAME}: ${DAYS_OLD} days — will be deleted"
  else
    git worktree remove "$wt_dir" --force 2>/dev/null || rm -rf "$wt_dir"
    # Clean up branch
    git branch -d "$BRANCH" 2>/dev/null || true
    green " ${NAME}: ${DAYS_OLD} days — deleted"
  fi
  CLEANED=$((CLEANED + 1))
done

echo ""
echo "Clean: ${CLEANED}, Warning: ${WARNED}"
green "Worktree GC completed"

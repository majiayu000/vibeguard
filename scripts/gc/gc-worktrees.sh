#!/usr/bin/env bash
# VibeGuard GC — Worktree Cleanup
#
# Scan the active worktree base (VIBEGUARD_WORKTREE_BASE, default <repo>.wt/)
# and delete worktrees that have been inactive for more than the specified
# number of days.
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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/project_config.sh
source "${SCRIPT_DIR}/../lib/project_config.sh"

MAX_DAYS="$(vg_config_positive_int VIBEGUARD_GC_WORKTREE_MAX_DAYS gc.worktree_max_days 7)"
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

normalize_worktree_base() {
  local base="${1%/}"
  local parent name

  [[ "$base" == /* ]] || base="${REPO_ROOT}/${base}"

  if [[ -d "$base" ]]; then
    cd "$base" && pwd -P
    return 0
  fi

  parent=$(dirname "$base")
  name=$(basename "$base")
  if [[ -d "$parent" ]]; then
    printf '%s/%s\n' "$(cd "$parent" && pwd -P)" "$name"
    return 0
  fi

  printf '%s\n' "$base"
}

WORKTREE_BASE="$(normalize_worktree_base "${VIBEGUARD_WORKTREE_BASE:-${REPO_ROOT}.wt}")"

WORKTREE_DIRS=()
[[ -d "$WORKTREE_BASE" ]] && WORKTREE_DIRS+=("$WORKTREE_BASE")

if [[ ${#WORKTREE_DIRS[@]} -eq 0 ]]; then
  green "No worktree directory, skip"
  exit 0
fi

NOW=$(date +%s)
CLEANED=0
WARNED=0

mtime_or_now() {
  local target="$1"
  local value
  value=$(stat -f %m "$target" 2>/dev/null || true)
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "$value"
    return 0
  fi
  value=$(stat -c %Y "$target" 2>/dev/null || true)
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "$value"
    return 0
  fi
  echo "$NOW"
}

for base in "${WORKTREE_DIRS[@]}"; do
  for wt_dir in "${base}"/*/; do
    [[ -d "$wt_dir" ]] || continue
    NAME=$(basename "$wt_dir")
    LABEL="${NAME}"

    # Get the latest modification time (get the latest file in the .git file or directory)
    if [[ -f "${wt_dir}.git" ]]; then
      LAST_MOD=$(mtime_or_now "${wt_dir}.git")
    else
      LAST_MOD=$(find "$wt_dir" -maxdepth 2 -type f -newer "$wt_dir" -print -quit 2>/dev/null | head -1)
      if [[ -z "$LAST_MOD" ]]; then
        LAST_MOD=$(mtime_or_now "$wt_dir")
      else
        LAST_MOD=$(mtime_or_now "$LAST_MOD")
      fi
    fi

    DAYS_OLD=$(( (NOW - LAST_MOD) / 86400 ))

    if [[ "$DAYS_OLD" -lt "$MAX_DAYS" ]]; then
      echo "${LABEL}: ${DAYS_OLD} days — reserved"
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
      yellow " ${LABEL}: ${DAYS_OLD} days — unmerged changes, skip"
      [[ "$HAS_CHANGES" == "true" ]] && yellow "Uncommitted changes"
      [[ "$UNMERGED" == "true" ]] && yellow "Branch ${BRANCH} is not merged"
      WARNED=$((WARNED + 1))
      continue
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      yellow " [DRY-RUN] ${LABEL}: ${DAYS_OLD} days — will be deleted"
    else
      git worktree remove "$wt_dir" --force 2>/dev/null || rm -rf "$wt_dir"
      # Clean up branch
      git branch -d "$BRANCH" 2>/dev/null || true
      green " ${LABEL}: ${DAYS_OLD} days — deleted"
    fi
    CLEANED=$((CLEANED + 1))
  done
done

echo ""
echo "Clean: ${CLEANED}, Warning: ${WARNED}"
green "Worktree GC completed"

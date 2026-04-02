#!/usr/bin/env bash
# VibeGuard Worktree Guard — Big changes to isolation assist
#
# Usage:
# bash worktree-guard.sh create [name] # Create worktree
# bash worktree-guard.sh list # List active worktrees
# bash worktree-guard.sh merge <name> # Merge the worktree branch to the current branch
# bash worktree-guard.sh remove <name> # Delete worktree
# bash worktree-guard.sh status <name> # Check worktree status
#
# worktree is created under .vibeguard/worktrees/, and the branch name is vg/<name>

set -euo pipefail

green() { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
red() { printf '\033[31m%s\033[0m\n' "$1"; }

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  red "Error: Not in git repository"
  exit 1
fi

REPO_ROOT=$(git rev-parse --show-toplevel)
WORKTREE_BASE="${REPO_ROOT}/.vibeguard/worktrees"
ACTION="${1:-help}"

case "$ACTION" in
  create)
    NAME="${2:-$(date +%Y%m%d-%H%M%S)}"
    BRANCH="vg/${NAME}"
    WORKTREE_PATH="${WORKTREE_BASE}/${NAME}"

    if [[ -d "$WORKTREE_PATH" ]]; then
      red "Error: worktree already exists: ${WORKTREE_PATH}"
      exit 1
    fi

    mkdir -p "$WORKTREE_BASE"
    git worktree add -b "$BRANCH" "$WORKTREE_PATH" HEAD
    green "worktree has been created:"
    echo "path: ${WORKTREE_PATH}"
    echo "branch: ${BRANCH}"
    echo ""
    echo "Usage:"
    echo "  cd ${WORKTREE_PATH}"
    echo " # Make changes here..."
    echo " # After completion: bash worktree-guard.sh merge ${NAME}"
    echo " # or give up: bash worktree-guard.sh remove ${NAME}"
    ;;

  list)
    git worktree list | grep -E "\.vibeguard/worktrees" || yellow "No active VibeGuard worktree"
    ;;

  status)
    NAME="${2:?Usage: worktree-guard.sh status <name>}"
    WORKTREE_PATH="${WORKTREE_BASE}/${NAME}"
    if [[ ! -d "$WORKTREE_PATH" ]]; then
      red "Error: worktree does not exist: ${WORKTREE_PATH}"
      exit 1
    fi
    echo "Worktree: ${NAME}"
    echo "Path: ${WORKTREE_PATH}"
    echo "Branch: vg/${NAME}"
    echo ""
    git -C "$WORKTREE_PATH" log --oneline -5
    echo ""
    git -C "$WORKTREE_PATH" status --short
    ;;

  merge)
    NAME="${2:?Usage: worktree-guard.sh merge <name>}"
    BRANCH="vg/${NAME}"
    WORKTREE_PATH="${WORKTREE_BASE}/${NAME}"

    if [[ ! -d "$WORKTREE_PATH" ]]; then
      red "Error: worktree does not exist: ${WORKTREE_PATH}"
      exit 1
    fi

    # Check if the worktree has any uncommitted changes
    if [[ -n "$(git -C "$WORKTREE_PATH" status --porcelain)" ]]; then
      red "Error: worktree has uncommitted changes, please submit or discard first"
      git -C "$WORKTREE_PATH" status --short
      exit 1
    fi

    CURRENT_BRANCH=$(git branch --show-current)
    echo "Merge ${BRANCH} -> ${CURRENT_BRANCH}"
    git merge "$BRANCH" --no-ff -m "merge: ${NAME} worktree changes merge"
    green "merge completed"
    echo ""
    yellow "Tip: After confirming everything is correct, run worktree-guard.sh remove ${NAME} to clean up"
    ;;

  remove)
    NAME="${2:?Usage: worktree-guard.sh remove <name>}"
    BRANCH="vg/${NAME}"
    WORKTREE_PATH="${WORKTREE_BASE}/${NAME}"

    if [[ -d "$WORKTREE_PATH" ]]; then
      git worktree remove "$WORKTREE_PATH" --force
      green "Deleted worktree: ${WORKTREE_PATH}"
    else
      yellow "worktree does not exist: ${WORKTREE_PATH}"
    fi

    # Delete branch (if merged)
    if git branch --list "$BRANCH" | grep -q .; then
      if git branch -d "$BRANCH" 2>/dev/null; then
        green "Deleted branch: ${BRANCH}"
      else
        yellow "Branch ${BRANCH} is not merged and is retained. Force deletion: git branch -D ${BRANCH}"
      fi
    fi
    ;;

  help|*)
    echo "VibeGuard Worktree Guard — Big changes to isolation assist"
    echo ""
    echo "Usage:"
    echo "worktree-guard.sh create [name] Create an isolated worktree"
    echo " worktree-guard.sh list List active worktrees"
    echo "worktree-guard.sh status <name> View worktree status"
    echo "worktree-guard.sh merge <name> Merge back to the current branch"
    echo " worktree-guard.sh remove <name> delete worktree and branches"
    ;;
esac

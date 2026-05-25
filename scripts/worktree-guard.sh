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
# worktree is created under <repo>.wt/ by default, and the branch name is vg/<name>

set -euo pipefail

green() { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
red() { printf '\033[31m%s\033[0m\n' "$1"; }

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  red "Error: Not in git repository"
  exit 1
fi

REPO_ROOT=$(git rev-parse --show-toplevel)
ACTION="${1:-help}"

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

# Default base sits next to the repo (<repo>.wt/) to keep the repo tree clean.
# Override with VIBEGUARD_WORKTREE_BASE for external SSDs, alternate hosts, etc.
WORKTREE_BASE="$(normalize_worktree_base "${VIBEGUARD_WORKTREE_BASE:-${REPO_ROOT}.wt}")"
LEGACY_WORKTREE_BASE="$(normalize_worktree_base "${REPO_ROOT}/.vibeguard/worktrees")"

same_path() {
  [[ "${1%/}" == "${2%/}" ]]
}

resolve_worktree_path() {
  local name="$1"
  local path="${WORKTREE_BASE}/${name}"

  if [[ -d "$path" ]]; then
    printf '%s\n' "$path"
    return 0
  fi

  local legacy_path="${LEGACY_WORKTREE_BASE}/${name}"
  if ! same_path "$legacy_path" "$path" && [[ -d "$legacy_path" ]]; then
    printf '%s\n' "$legacy_path"
    return 0
  fi

  printf '%s\n' "$path"
  return 1
}

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
    LIST_BASES=()

    for base in "$WORKTREE_BASE" "$LEGACY_WORKTREE_BASE"; do
      duplicate=0
      for existing in "${LIST_BASES[@]}"; do
        if same_path "$base" "$existing"; then
          duplicate=1
          break
        fi
      done

      if [[ "$duplicate" -eq 0 && -d "$base" ]]; then
        LIST_BASES+=("$(cd "$base" && pwd -P)")
      fi
    done

    found=0
    if [[ "${#LIST_BASES[@]}" -gt 0 ]]; then
      while IFS= read -r line; do
        [[ "$line" == worktree\ * ]] || continue
        path="${line#worktree }"
        for base in "${LIST_BASES[@]}"; do
          if [[ "$path" == "$base" || "$path" == "$base"/* ]]; then
            echo "$path"
            found=1
            break
          fi
        done
      done < <(git worktree list --porcelain)
    fi

    [[ "$found" -eq 1 ]] || yellow "No active VibeGuard worktree"
    ;;

  status)
    NAME="${2:?Usage: worktree-guard.sh status <name>}"
    if ! WORKTREE_PATH="$(resolve_worktree_path "$NAME")"; then
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

    if ! WORKTREE_PATH="$(resolve_worktree_path "$NAME")"; then
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

    if WORKTREE_PATH="$(resolve_worktree_path "$NAME")"; then
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

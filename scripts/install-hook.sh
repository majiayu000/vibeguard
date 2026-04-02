#!/usr/bin/env bash
# VibeGuard install-hook — Install git hooks to the target project
#
# Installed hooks:
# pre-commit → hooks/pre-commit-guard.sh (pre-commit quality check)
# pre-push → hooks/git/pre-push (force push interception)
#
# Usage:
# bash scripts/install-hook.sh <project_dir> # Install
# bash scripts/install-hook.sh --remove <dir> # Uninstall
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PRECOMMIT_SCRIPT="${REPO_DIR}/hooks/pre-commit-guard.sh"
PREPUSH_SCRIPT="${REPO_DIR}/hooks/git/pre-push"

green() { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
red() { printf '\033[31m%s\033[0m\n' "$1"; }

if [[ "${1:-}" == "--remove" ]]; then
  PROJECT_DIR="${2:?Usage: scripts/install-hook.sh --remove <project_dir>}"
  HOOK_DIR="${PROJECT_DIR}/.git/hooks"

  PRECOMMIT_PATH="${HOOK_DIR}/pre-commit"
  if [[ -L "$PRECOMMIT_PATH" ]] && readlink "$PRECOMMIT_PATH" | grep -q "pre-commit-guard"; then
    rm -f "$PRECOMMIT_PATH"
    green "Removed: ${PRECOMMIT_PATH}"
  else
    yellow "VibeGuard pre-commit hook not found: ${PRECOMMIT_PATH}"
  fi

  PREPUSH_PATH="${HOOK_DIR}/pre-push"
  if [[ -L "$PREPUSH_PATH" ]] && [[ "$(readlink "$PREPUSH_PATH")" == "$PREPUSH_SCRIPT" ]]; then
    rm -f "$PREPUSH_PATH"
    green "Removed: ${PREPUSH_PATH}"
  else
    yellow "VibeGuard pre-push hook not found: ${PREPUSH_PATH}"
  fi

  exit 0
fi

PROJECT_DIR="${1:?Usage: scripts/install-hook.sh <project_dir>}"

if [[ ! -d "${PROJECT_DIR}/.git" ]]; then
  red "Error: ${PROJECT_DIR} is not a git repository"
  exit 1
fi

HOOK_DIR="${PROJECT_DIR}/.git/hooks"
mkdir -p "$HOOK_DIR"

# --- Pre-check: all conflicts are verified before any installation ---
PRECOMMIT_PATH="${HOOK_DIR}/pre-commit"
PREPUSH_PATH="${HOOK_DIR}/pre-push"

if [[ -f "$PRECOMMIT_PATH" ]] && [[ ! -L "$PRECOMMIT_PATH" ]]; then
  red "Error: ${PRECOMMIT_PATH} already exists and is not a symlink"
  red "Please handle it manually and try again, or add it to the existing hook:"
  echo "  VIBEGUARD_DIR=\"${REPO_DIR}\" bash \"${PRECOMMIT_SCRIPT}\""
  exit 1
fi

if [[ -f "$PREPUSH_PATH" ]] && [[ ! -L "$PREPUSH_PATH" ]]; then
  red "Error: ${PREPUSH_PATH} already exists and is not a symlink"
  red "Please handle it manually and try again, or manually merge the logic of ${PREPUSH_SCRIPT}"
  exit 1
fi

# --- Installation (pre-check passed, no intermediate failure state) ---
ln -sf "$PRECOMMIT_SCRIPT" "$PRECOMMIT_PATH"
green "Installed: ${PRECOMMIT_PATH} -> ${PRECOMMIT_SCRIPT}"

ln -sf "$PREPUSH_SCRIPT" "$PREPUSH_PATH"
green "Installed: ${PREPUSH_PATH} -> ${PREPUSH_SCRIPT}"

echo ""
echo "Prompt:"
echo "Skip pre-commit check: VIBEGUARD_SKIP_PRECOMMIT=1 git commit -m \"msg\""
echo "Adjust timeout: VIBEGUARD_PRECOMMIT_TIMEOUT=15 git commit -m \"msg\""
echo "Uninstall: bash scripts/install-hook.sh --remove ${PROJECT_DIR}"

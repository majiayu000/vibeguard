#!/usr/bin/env bash
# VibeGuard Hook Wrapper — A hook distributor compatible with all platforms
#
# All hooks in settings.json are called indirectly through this wrapper.
# Avoid hardcoding absolute paths. Repo relocation only requires updating ~/.vibeguard/repo-path.
#
# Usage: bash ~/.vibeguard/run-hook.sh <hook-script-name> [args...]
# Example: bash ~/.vibeguard/run-hook.sh stop-guard.sh

set -euo pipefail

HOOK_NAME="${1:?Usage: run-hook.sh <hook-name>}"
shift

INSTALLED_DIR="${HOME}/.vibeguard/installed/hooks"
HOOK_PATH="${INSTALLED_DIR}/${HOOK_NAME}"

if [[ ! -d "$INSTALLED_DIR" ]]; then
  # Fallback: legacy direct-repo mode
  REPO_PATH_FILE="${HOME}/.vibeguard/repo-path"
  if [[ ! -f "$REPO_PATH_FILE" ]]; then
    echo "ERROR: ${REPO_PATH_FILE} not found. Re-run: bash <vibeguard-repo>/scripts/setup/install.sh" >&2
    exit 1
  fi
  REPO_DIR=$(<"$REPO_PATH_FILE")
  HOOK_PATH="${REPO_DIR}/hooks/${HOOK_NAME}"
fi

if [[ ! -f "$HOOK_PATH" ]]; then
  echo "ERROR: hook not found: ${HOOK_PATH}" >&2
  exit 1
fi

# Ensure Python writes UTF-8 regardless of the terminal's default encoding (fixes Windows CP-1252)
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

exec bash "$HOOK_PATH" "$@"

#!/usr/bin/env bash
# VibeGuard Hook Wrapper — A hook distributor compatible with all platforms
#
# All hooks in settings.json are called indirectly through this wrapper.
# Avoid hardcoding absolute paths. Repo relocation only requires updating ~/.vibeguard/repo-path.
#
# Usage: bash ~/.vibeguard/run-hook.sh <hook-script-name> [args...]
# Example: bash ~/.vibeguard/run-hook.sh stop-guard.sh

set -euo pipefail

WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_NAME="${1:?Usage: run-hook.sh <hook-name>}"
shift

INSTALLED_DIR="${HOME}/.vibeguard/installed/hooks"
HOOK_PATH="${INSTALLED_DIR}/${HOOK_NAME}"
RUNTIME_ENV_PATH="${WRAPPER_DIR}/_lib/runtime_env.sh"
if [[ ! -f "$RUNTIME_ENV_PATH" && -f "${INSTALLED_DIR}/_lib/runtime_env.sh" ]]; then
  RUNTIME_ENV_PATH="${INSTALLED_DIR}/_lib/runtime_env.sh"
fi

if [[ ! -d "$INSTALLED_DIR" ]]; then
  # Fallback: legacy direct-repo mode
  REPO_PATH_FILE="${HOME}/.vibeguard/repo-path"
  if [[ ! -f "$REPO_PATH_FILE" ]]; then
    echo "ERROR: ${REPO_PATH_FILE} not found. Re-run: bash <vibeguard-repo>/scripts/setup/install.sh" >&2
    exit 1
  fi
  REPO_DIR=$(<"$REPO_PATH_FILE")
  HOOK_PATH="${REPO_DIR}/hooks/${HOOK_NAME}"
  if [[ ! -f "$RUNTIME_ENV_PATH" && -f "${REPO_DIR}/hooks/_lib/runtime_env.sh" ]]; then
    RUNTIME_ENV_PATH="${REPO_DIR}/hooks/_lib/runtime_env.sh"
  fi
fi

if [[ ! -f "$HOOK_PATH" ]]; then
  echo "ERROR: hook not found: ${HOOK_PATH}" >&2
  exit 1
fi

export VIBEGUARD_CLI="${VIBEGUARD_CLI:-claude}"
if [[ -f "$RUNTIME_ENV_PATH" ]]; then
  # shellcheck source=hooks/_lib/runtime_env.sh
  source "$RUNTIME_ENV_PATH"
  _vg_prepare_hook_runtime_env
else
  # Ensure Python writes UTF-8 regardless of the terminal's default encoding (fixes Windows CP-1252)
  export PYTHONUTF8=1
  export PYTHONIOENCODING=utf-8
fi

exec bash "$HOOK_PATH" "$@"

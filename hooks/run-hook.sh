#!/usr/bin/env bash
# VibeGuard Hook Wrapper — 全平台兼容的 hook 分发器
#
# settings.json 中所有 hook 通过此 wrapper 间接调用，
# 避免硬编码绝对路径。repo 搬家只需更新 ~/.vibeguard/repo-path。
#
# 用法: bash ~/.vibeguard/run-hook.sh <hook-script-name> [args...]
# 示例: bash ~/.vibeguard/run-hook.sh stop-guard.sh

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

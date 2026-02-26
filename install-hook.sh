#!/usr/bin/env bash
# VibeGuard install-hook — 将 pre-commit guard 安装到目标项目
#
# 用法：
#   bash install-hook.sh <project_dir>    # 安装
#   bash install-hook.sh --remove <dir>   # 卸载
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARD_SCRIPT="${REPO_DIR}/hooks/pre-commit-guard.sh"

green() { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
red() { printf '\033[31m%s\033[0m\n' "$1"; }

if [[ "${1:-}" == "--remove" ]]; then
  PROJECT_DIR="${2:?用法: install-hook.sh --remove <project_dir>}"
  HOOK_PATH="${PROJECT_DIR}/.git/hooks/pre-commit"
  if [[ -L "$HOOK_PATH" ]] && readlink "$HOOK_PATH" | grep -q "pre-commit-guard"; then
    rm -f "$HOOK_PATH"
    green "已移除: ${HOOK_PATH}"
  else
    yellow "未找到 VibeGuard pre-commit hook: ${HOOK_PATH}"
  fi
  exit 0
fi

PROJECT_DIR="${1:?用法: install-hook.sh <project_dir>}"

if [[ ! -d "${PROJECT_DIR}/.git" ]]; then
  red "错误: ${PROJECT_DIR} 不是 git 仓库"
  exit 1
fi

HOOK_DIR="${PROJECT_DIR}/.git/hooks"
HOOK_PATH="${HOOK_DIR}/pre-commit"

mkdir -p "$HOOK_DIR"

# 检查是否已有 pre-commit hook
if [[ -f "$HOOK_PATH" ]] && [[ ! -L "$HOOK_PATH" ]]; then
  red "错误: ${HOOK_PATH} 已存在且不是 symlink"
  red "请手动处理后重试，或在现有 hook 中添加:"
  echo "  VIBEGUARD_DIR=\"${REPO_DIR}\" bash \"${GUARD_SCRIPT}\""
  exit 1
fi

# 创建 symlink
ln -sf "$GUARD_SCRIPT" "$HOOK_PATH"

# 设置环境变量，让 guard 能找到 log.sh
green "已安装: ${HOOK_PATH} -> ${GUARD_SCRIPT}"
echo ""
echo "提示："
echo "  跳过检查: VIBEGUARD_SKIP_PRECOMMIT=1 git commit -m \"msg\""
echo "  调整超时: VIBEGUARD_PRECOMMIT_TIMEOUT=15 git commit -m \"msg\""
echo "  卸载: bash ${REPO_DIR}/install-hook.sh --remove ${PROJECT_DIR}"

#!/usr/bin/env bash
# VibeGuard install-hook — 将 git hooks 安装到目标项目
#
# 安装的 hooks：
#   pre-commit  → hooks/pre-commit-guard.sh （提交前质量检查）
#   pre-push    → hooks/git/pre-push        （force push 拦截）
#
# 用法：
#   bash scripts/install-hook.sh <project_dir>    # 安装
#   bash scripts/install-hook.sh --remove <dir>   # 卸载
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PRECOMMIT_SCRIPT="${REPO_DIR}/hooks/pre-commit-guard.sh"
PREPUSH_SCRIPT="${REPO_DIR}/hooks/git/pre-push"

green() { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
red() { printf '\033[31m%s\033[0m\n' "$1"; }

if [[ "${1:-}" == "--remove" ]]; then
  PROJECT_DIR="${2:?用法: scripts/install-hook.sh --remove <project_dir>}"
  HOOK_DIR="${PROJECT_DIR}/.git/hooks"

  PRECOMMIT_PATH="${HOOK_DIR}/pre-commit"
  if [[ -L "$PRECOMMIT_PATH" ]] && readlink "$PRECOMMIT_PATH" | grep -q "pre-commit-guard"; then
    rm -f "$PRECOMMIT_PATH"
    green "已移除: ${PRECOMMIT_PATH}"
  else
    yellow "未找到 VibeGuard pre-commit hook: ${PRECOMMIT_PATH}"
  fi

  PREPUSH_PATH="${HOOK_DIR}/pre-push"
  if [[ -L "$PREPUSH_PATH" ]] && [[ "$(readlink "$PREPUSH_PATH")" == "$PREPUSH_SCRIPT" ]]; then
    rm -f "$PREPUSH_PATH"
    green "已移除: ${PREPUSH_PATH}"
  else
    yellow "未找到 VibeGuard pre-push hook: ${PREPUSH_PATH}"
  fi

  exit 0
fi

PROJECT_DIR="${1:?用法: scripts/install-hook.sh <project_dir>}"

if [[ ! -d "${PROJECT_DIR}/.git" ]]; then
  red "错误: ${PROJECT_DIR} 不是 git 仓库"
  exit 1
fi

HOOK_DIR="${PROJECT_DIR}/.git/hooks"
mkdir -p "$HOOK_DIR"

# --- 预检查：所有冲突在任何安装之前统一验证 ---
PRECOMMIT_PATH="${HOOK_DIR}/pre-commit"
PREPUSH_PATH="${HOOK_DIR}/pre-push"

if [[ -f "$PRECOMMIT_PATH" ]] && [[ ! -L "$PRECOMMIT_PATH" ]]; then
  red "错误: ${PRECOMMIT_PATH} 已存在且不是 symlink"
  red "请手动处理后重试，或在现有 hook 中添加:"
  echo "  VIBEGUARD_DIR=\"${REPO_DIR}\" bash \"${PRECOMMIT_SCRIPT}\""
  exit 1
fi

if [[ -f "$PREPUSH_PATH" ]] && [[ ! -L "$PREPUSH_PATH" ]]; then
  red "错误: ${PREPUSH_PATH} 已存在且不是 symlink"
  red "请手动处理后重试，或手动合并 ${PREPUSH_SCRIPT} 的逻辑"
  exit 1
fi

# --- 安装（预检查已通过，无中间失败态）---
ln -sf "$PRECOMMIT_SCRIPT" "$PRECOMMIT_PATH"
green "已安装: ${PRECOMMIT_PATH} -> ${PRECOMMIT_SCRIPT}"

ln -sf "$PREPUSH_SCRIPT" "$PREPUSH_PATH"
green "已安装: ${PREPUSH_PATH} -> ${PREPUSH_SCRIPT}"

echo ""
echo "提示："
echo "  跳过 pre-commit 检查: VIBEGUARD_SKIP_PRECOMMIT=1 git commit -m \"msg\""
echo "  调整超时: VIBEGUARD_PRECOMMIT_TIMEOUT=15 git commit -m \"msg\""
echo "  卸载: bash scripts/install-hook.sh --remove ${PROJECT_DIR}"

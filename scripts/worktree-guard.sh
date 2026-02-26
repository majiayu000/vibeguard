#!/usr/bin/env bash
# VibeGuard Worktree Guard — 大改动隔离辅助
#
# 用法：
#   bash worktree-guard.sh create [name]     # 创建 worktree
#   bash worktree-guard.sh list              # 列出活跃 worktree
#   bash worktree-guard.sh merge <name>      # 合并 worktree 分支到当前分支
#   bash worktree-guard.sh remove <name>     # 删除 worktree
#   bash worktree-guard.sh status <name>     # 查看 worktree 状态
#
# worktree 创建在 .vibeguard/worktrees/ 下，分支名为 vg/<name>

set -euo pipefail

green() { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
red() { printf '\033[31m%s\033[0m\n' "$1"; }

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  red "错误: 不在 git 仓库中"
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
      red "错误: worktree 已存在: ${WORKTREE_PATH}"
      exit 1
    fi

    mkdir -p "$WORKTREE_BASE"
    git worktree add -b "$BRANCH" "$WORKTREE_PATH" HEAD
    green "已创建 worktree:"
    echo "  路径: ${WORKTREE_PATH}"
    echo "  分支: ${BRANCH}"
    echo ""
    echo "使用方式:"
    echo "  cd ${WORKTREE_PATH}"
    echo "  # 在这里做修改..."
    echo "  # 完成后: bash worktree-guard.sh merge ${NAME}"
    echo "  # 或放弃: bash worktree-guard.sh remove ${NAME}"
    ;;

  list)
    git worktree list | grep -E "\.vibeguard/worktrees" || yellow "无活跃的 VibeGuard worktree"
    ;;

  status)
    NAME="${2:?用法: worktree-guard.sh status <name>}"
    WORKTREE_PATH="${WORKTREE_BASE}/${NAME}"
    if [[ ! -d "$WORKTREE_PATH" ]]; then
      red "错误: worktree 不存在: ${WORKTREE_PATH}"
      exit 1
    fi
    echo "Worktree: ${NAME}"
    echo "路径: ${WORKTREE_PATH}"
    echo "分支: vg/${NAME}"
    echo ""
    git -C "$WORKTREE_PATH" log --oneline -5
    echo ""
    git -C "$WORKTREE_PATH" status --short
    ;;

  merge)
    NAME="${2:?用法: worktree-guard.sh merge <name>}"
    BRANCH="vg/${NAME}"
    WORKTREE_PATH="${WORKTREE_BASE}/${NAME}"

    if [[ ! -d "$WORKTREE_PATH" ]]; then
      red "错误: worktree 不存在: ${WORKTREE_PATH}"
      exit 1
    fi

    # 检查 worktree 是否有未提交变更
    if [[ -n "$(git -C "$WORKTREE_PATH" status --porcelain)" ]]; then
      red "错误: worktree 有未提交变更，请先提交或丢弃"
      git -C "$WORKTREE_PATH" status --short
      exit 1
    fi

    CURRENT_BRANCH=$(git branch --show-current)
    echo "合并 ${BRANCH} -> ${CURRENT_BRANCH}"
    git merge "$BRANCH" --no-ff -m "merge: ${NAME} worktree 改动合入"
    green "合并完成"
    echo ""
    yellow "提示: 确认无误后运行 worktree-guard.sh remove ${NAME} 清理"
    ;;

  remove)
    NAME="${2:?用法: worktree-guard.sh remove <name>}"
    BRANCH="vg/${NAME}"
    WORKTREE_PATH="${WORKTREE_BASE}/${NAME}"

    if [[ -d "$WORKTREE_PATH" ]]; then
      git worktree remove "$WORKTREE_PATH" --force
      green "已删除 worktree: ${WORKTREE_PATH}"
    else
      yellow "worktree 不存在: ${WORKTREE_PATH}"
    fi

    # 删除分支（如果已合并）
    if git branch --list "$BRANCH" | grep -q .; then
      if git branch -d "$BRANCH" 2>/dev/null; then
        green "已删除分支: ${BRANCH}"
      else
        yellow "分支 ${BRANCH} 未合并，保留。强制删除: git branch -D ${BRANCH}"
      fi
    fi
    ;;

  help|*)
    echo "VibeGuard Worktree Guard — 大改动隔离辅助"
    echo ""
    echo "用法："
    echo "  worktree-guard.sh create [name]   创建隔离 worktree"
    echo "  worktree-guard.sh list            列出活跃 worktree"
    echo "  worktree-guard.sh status <name>   查看 worktree 状态"
    echo "  worktree-guard.sh merge <name>    合并回当前分支"
    echo "  worktree-guard.sh remove <name>   删除 worktree 和分支"
    ;;
esac

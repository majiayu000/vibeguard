#!/usr/bin/env bash
# VibeGuard GC — Worktree 清理
#
# 扫描 .vibeguard/worktrees/，删除超过指定天数未活跃的 worktree。
# 有未合并变更的 worktree 只警告不删除。
#
# 用法：
#   bash gc-worktrees.sh              # 默认 7 天
#   bash gc-worktrees.sh --days 14    # 14 天
#   bash gc-worktrees.sh --dry-run    # 只报告

set -euo pipefail

green() { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
red() { printf '\033[31m%s\033[0m\n' "$1"; }

MAX_DAYS=7
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days) MAX_DAYS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) shift ;;
  esac
done

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  red "错误: 不在 git 仓库中"
  exit 1
fi

REPO_ROOT=$(git rev-parse --show-toplevel)
WORKTREE_BASE="${REPO_ROOT}/.vibeguard/worktrees"

if [[ ! -d "$WORKTREE_BASE" ]]; then
  green "无 worktree 目录，跳过"
  exit 0
fi

NOW=$(date +%s)
CLEANED=0
WARNED=0

for wt_dir in "${WORKTREE_BASE}"/*/; do
  [[ -d "$wt_dir" ]] || continue
  NAME=$(basename "$wt_dir")

  # 获取最近修改时间（取 .git 文件或目录内最新文件）
  if [[ -f "${wt_dir}.git" ]]; then
    LAST_MOD=$(stat -f %m "${wt_dir}.git" 2>/dev/null || stat -c %Y "${wt_dir}.git" 2>/dev/null || echo "$NOW")
  else
    LAST_MOD=$(find "$wt_dir" -maxdepth 2 -type f -newer "$wt_dir" -print -quit 2>/dev/null | head -1)
    if [[ -z "$LAST_MOD" ]]; then
      LAST_MOD=$(stat -f %m "$wt_dir" 2>/dev/null || stat -c %Y "$wt_dir" 2>/dev/null || echo "$NOW")
    else
      LAST_MOD=$(stat -f %m "$LAST_MOD" 2>/dev/null || stat -c %Y "$LAST_MOD" 2>/dev/null || echo "$NOW")
    fi
  fi

  DAYS_OLD=$(( (NOW - LAST_MOD) / 86400 ))

  if [[ "$DAYS_OLD" -lt "$MAX_DAYS" ]]; then
    echo "  ${NAME}: ${DAYS_OLD} 天 — 保留"
    continue
  fi

  # 检查未合并变更
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
    yellow "  ${NAME}: ${DAYS_OLD} 天 — 有未合并变更，跳过"
    [[ "$HAS_CHANGES" == "true" ]] && yellow "    未提交的修改"
    [[ "$UNMERGED" == "true" ]] && yellow "    分支 ${BRANCH} 未合并"
    WARNED=$((WARNED + 1))
    continue
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    yellow "  [DRY-RUN] ${NAME}: ${DAYS_OLD} 天 — 将删除"
  else
    git worktree remove "$wt_dir" --force 2>/dev/null || rm -rf "$wt_dir"
    # 清理分支
    git branch -d "$BRANCH" 2>/dev/null || true
    green "  ${NAME}: ${DAYS_OLD} 天 — 已删除"
  fi
  CLEANED=$((CLEANED + 1))
done

echo ""
echo "清理: ${CLEANED}, 警告: ${WARNED}"
green "Worktree GC 完成"

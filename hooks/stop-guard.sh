#!/usr/bin/env bash
# VibeGuard Stop Hook — 完成前验证门禁
#
# AI 会话结束时检查是否有未提交的源码变更。
# 有未提交变更 → exit 2（阻塞，stderr 反馈给 Claude）
# 无变更或非 git 仓库 → exit 0（静默通过）

set -euo pipefail

source "$(dirname "$0")/log.sh"

# 不在 git 仓库 → 跳过
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  exit 0
fi

# 检查是否有未提交的源码变更（staged + unstaged）
changed_source_files=""
while IFS= read -r file; do
  if [[ -n "$file" ]] && vg_is_source_file "$file"; then
    changed_source_files="${changed_source_files}${file}"$'\n'
  fi
done < <(git diff --name-only HEAD 2>/dev/null; git diff --name-only --cached 2>/dev/null)

# 去重
if [[ -n "$changed_source_files" ]]; then
  changed_source_files=$(echo "$changed_source_files" | sort -u)
  count=$(echo "$changed_source_files" | grep -c . || true)

  vg_log "stop-guard" "Stop" "gate" "uncommitted source changes: ${count} files" "$(echo "$changed_source_files" | head -5 | tr '\n' ' ')"

  # exit 0: log only, do not block — Claude cannot commit in Stop context,
  # so exit 2 here causes an infinite loop (feedback → response → stop hooks → repeat)
  exit 0
fi

vg_log "stop-guard" "Stop" "pass" "" ""
exit 0

#!/usr/bin/env bash
# VibeGuard Stop Hook — 完成前验证门禁
#
# AI 会话结束时检查是否有未提交的源码变更。
# 有未提交变更 → exit 2（阻塞，stderr 反馈给 Claude）
# 无变更或非 git 仓库 → exit 0（静默通过）

set -euo pipefail

source "$(dirname "$0")/log.sh"

# --- stop_hook_active 检查：防止 Stop hook 触发无限循环 (#10205, continue:true) ---
# Claude Code 在 Stop hook 再次触发时会在 input JSON 中注入 stop_hook_active=true
STOP_HOOK_INPUT=$(cat 2>/dev/null || true)
if echo "$STOP_HOOK_INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    if d.get("stop_hook_active") == True:
        sys.exit(0)
except Exception:
    pass
sys.exit(1)
' 2>/dev/null; then
  exit 0
fi

# CI 环境跳过（与 post-build-check.sh 一致，防止 CI 中 hook 循环 #3573）
if [[ -n "${CI:-}" ]]; then
  exit 0
fi

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

#!/usr/bin/env bash
# VibeGuard PreToolUse(Bash) Hook
#
# 硬拦截不可逆的危险命令：
#   - git push --force / -f（覆盖远端历史）
#   - git reset --hard（丢弃未提交改动）
#   - git checkout . / git restore .（丢弃所有改动）
#   - git clean -f（删除未跟踪文件）
#   - rm -rf 项目根目录或敏感路径

set -euo pipefail

INPUT=$(cat)

COMMAND=$(echo "$INPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('tool_input', {}).get('command', ''))
" 2>/dev/null || echo "")

if [[ -z "$COMMAND" ]]; then
  exit 0
fi

block() {
  local reason="$1"
  cat <<BLOCK_EOF
{
  "decision": "block",
  "reason": "VIBEGUARD 拦截：${reason}"
}
BLOCK_EOF
  exit 0
}

# git push --force / -f（拦截所有 force push）
if echo "$COMMAND" | grep -qE 'git\s+push\s+.*(-f|--force)'; then
  block "禁止 force push（覆盖远端历史，丢失他人工作）。替代方案：git push 正常推送；如需覆盖自己的 PR 分支，先用 git rebase 再 git push --force-with-lease（更安全）。"
fi

# git reset --hard（丢弃所有未提交的改动）
if echo "$COMMAND" | grep -qE 'git\s+reset\s+--hard'; then
  block "禁止 git reset --hard（不可逆丢弃未提交改动）。替代方案：git stash（暂存可恢复）、git revert <commit>（创建反转 commit）、git reset --soft <commit>（保留改动在暂存区）。"
fi

# git checkout . / git restore .（丢弃所有改动）
if echo "$COMMAND" | grep -qE 'git\s+(checkout|restore)\s+\.'; then
  block "禁止 git checkout/restore .（批量丢弃所有改动）。替代方案：git checkout -- <具体文件> 指定要丢弃的文件；git stash 暂存所有改动（可恢复）；git diff 先查看改动再决定。"
fi

# git clean -f（删除未跟踪文件）
if echo "$COMMAND" | grep -qE 'git\s+clean\s+.*-f'; then
  block "禁止 git clean -f（永久删除未跟踪文件，不可恢复）。替代方案：git clean -n（dry run 预览）先查看会删什么；git stash --include-untracked 暂存未跟踪文件；手动 rm 指定文件。"
fi

# rm -rf / 或 rm -rf ~（灾难性删除）
if echo "$COMMAND" | grep -qE 'rm\s+.*-[a-zA-Z]*r[a-zA-Z]*f.*\s+(/|~|/home|/Users)\s*$'; then
  block "禁止 rm -rf 根目录或用户主目录（灾难性操作，系统不可恢复）。替代方案：rm -rf <具体子目录> 指定精确路径；rm -ri 交互式确认；先 ls 确认目标再删除。"
fi

# 通过所有检查 → 放行
exit 0

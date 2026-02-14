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
  block "禁止 force push。这会覆盖远端提交历史，可能丢失其他人的工作。请使用 git push（不带 --force）。"
fi

# git reset --hard（丢弃所有未提交的改动）
if echo "$COMMAND" | grep -qE 'git\s+reset\s+--hard'; then
  block "禁止 git reset --hard。这会丢弃所有未提交的改动且不可恢复。如需回退，请使用 git stash 或 git revert。"
fi

# git checkout . / git restore .（丢弃所有改动）
if echo "$COMMAND" | grep -qE 'git\s+(checkout|restore)\s+\.'; then
  block "禁止 git checkout/restore .（丢弃所有改动）。请指定具体文件，而非全部丢弃。"
fi

# git clean -f（删除未跟踪文件）
if echo "$COMMAND" | grep -qE 'git\s+clean\s+.*-f'; then
  block "禁止 git clean -f。这会永久删除未跟踪文件。请手动确认后再操作。"
fi

# rm -rf / 或 rm -rf ~（灾难性删除）
if echo "$COMMAND" | grep -qE 'rm\s+.*-[a-zA-Z]*r[a-zA-Z]*f.*\s+(/|~|/home|/Users)\s*$'; then
  block "禁止 rm -rf 根目录或用户主目录。这是灾难性操作。"
fi

# 通过所有检查 → 放行
exit 0

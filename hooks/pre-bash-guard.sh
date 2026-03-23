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

source "$(dirname "$0")/log.sh"

INPUT=$(cat)

COMMAND=$(echo "$INPUT" | vg_json_field "tool_input.command")

if [[ -z "$COMMAND" ]]; then
  exit 0
fi

# 移除 heredoc 内容，避免多行文本造成误报
# 覆盖变体: <<EOF, <<'EOF', <<"EOF", <<-EOF, <<-'EOF', << 'EOF' 等
COMMAND_NO_HEREDOC=$(echo "$COMMAND" | python3 -c '
import re, sys
cmd = sys.stdin.read()
# 匹配 <<[-]? 可选空格 可选引号 终止符 可选引号，直到行首终止符
cmd = re.sub(r"<<-?\s*[\"'"'"']?(\w+)[\"'"'"']?.*?\n\1", "", cmd, flags=re.DOTALL)
print(cmd)
' 2>/dev/null || echo "$COMMAND")

# 剥离引号内容（commit message、echo 字符串等），避免文本内容触发误报
# 保留命令结构，用空字符串替代引号内容
COMMAND_STRIPPED=$(echo "$COMMAND_NO_HEREDOC" | python3 -c "
import re, sys
cmd = sys.stdin.read()
# 移除双引号和单引号内容
cmd = re.sub(r'\"[^\"]*\"', '\"\"', cmd)
cmd = re.sub(r\"'[^']*'\", \"''\", cmd)
print(cmd)
" 2>/dev/null || echo "$COMMAND_NO_HEREDOC")

# 路径扫描使用：去掉引号字符但保留内容，防止 rm -rf \"/Users/...\" 绕过
COMMAND_PATH_SCAN=$(printf '%s' "$COMMAND_NO_HEREDOC" | tr -d "\"'")

block() {
  local reason="$1"
  vg_log "pre-bash-guard" "Bash" "block" "$reason" "$COMMAND"
  cat <<BLOCK_EOF
{
  "decision": "block",
  "reason": "VIBEGUARD 拦截：${reason}"
}
BLOCK_EOF
  exit 0
}

# git push --force / -f（覆盖远端历史）
# 允许 --force-with-lease（更安全的并发保护）
if echo "$COMMAND_STRIPPED" | grep -qE 'git\s+push\b'; then
  if echo "$COMMAND_STRIPPED" | grep -qE '(^|[[:space:]])(--force|-f)([[:space:]]|$)' \
    && ! echo "$COMMAND_STRIPPED" | grep -qE '(^|[[:space:]])--force-with-lease([[:space:]]|$)'; then
    block "禁止 git push --force/-f（会覆盖远端历史，影响团队协作）。替代方案：git push --force-with-lease（带并发保护）；或通过 revert / 新提交修复问题。"
  fi
fi

# git reset --hard（丢弃未提交改动）
if echo "$COMMAND_STRIPPED" | grep -qE 'git\s+reset\s+--hard(\s|$)'; then
  block "禁止 git reset --hard（会丢弃工作区和暂存区改动）。替代方案：git restore --staged <file> + git checkout -- <file> 精确回退；或 git stash 暂存后再处理。"
fi

# git checkout . / git restore .（丢弃所有改动）
# 只匹配纯 "." 结尾，排除 git checkout ./src/file 等合法路径操作
if echo "$COMMAND_STRIPPED" | grep -qE 'git\s+(checkout|restore)\s+\.\s*(;|&&|\|\||$)'; then
  block "禁止 git checkout/restore .（批量丢弃所有改动）。替代方案：git checkout -- <具体文件> 指定要丢弃的文件；git stash 暂存所有改动（可恢复）；git diff 先查看改动再决定。"
fi

# git clean -f（删除未跟踪文件）
if echo "$COMMAND_STRIPPED" | grep -qE 'git\s+clean\s+.*-f'; then
  block "禁止 git clean -f（永久删除未跟踪文件，不可恢复）。替代方案：git clean -n（dry run 预览）先查看会删什么；git stash --include-untracked 暂存未跟踪文件；手动 rm 指定文件。"
fi

# rm -rf 危险路径检测（覆盖 rm -rf, rm -fr, rm -Rf, rm --recursive --force 等变体）
# 先在"去引号内容"的命令结构中识别 rm -rf 命令，再在保留路径内容的文本里做危险路径匹配
if echo "$COMMAND_STRIPPED" | grep -qE '(^|[;&|][[:space:]]*)(sudo[[:space:]]+)?(\\?rm)[[:space:]]+((-[a-zA-Z]*([rR][a-zA-Z]*f|f[a-zA-Z]*[rR]))|(--(recursive|force)[[:space:]]+--(recursive|force)))([[:space:]]|$)'; then
  DANGEROUS=false
  # 危险路径：根目录、家目录（含 /Users/xxx、/home/xxx）、系统目录
  for pattern in \
    '[[:space:]]/([[:space:];|&]|$)' \
    '[[:space:]]~([[:space:];|&/]|$)' \
    '\$HOME' \
    '[[:space:]]/Users(/[^/[:space:];|&]*)?([[:space:];|&]|$)' \
    '[[:space:]]/home(/[^/[:space:];|&]*)?([[:space:];|&]|$)' \
    '[[:space:]]/(etc|var|usr|bin|sbin|opt|System|Library)([[:space:];|&/]|$)'; do
    if echo "$COMMAND_PATH_SCAN" | grep -qE "$pattern"; then
      DANGEROUS=true
      break
    fi
  done
  if [[ "$DANGEROUS" == true ]]; then
    block "禁止 rm -rf 危险路径（根目录、家目录、系统目录不可恢复）。替代方案：rm -rf <具体深层子目录> 指定精确路径；rm -ri 交互式确认；先 ls 确认目标再删除。"
  fi
fi


# --- git commit 拦截：Claude Code 无 PreCommit 事件，通过 Bash hook 补位 ---
if echo "$COMMAND_STRIPPED" | grep -qE 'git\s+commit\b'; then
  # 显式跳过
  if ! echo "$COMMAND" | grep -qE 'VIBEGUARD_SKIP_PRECOMMIT=1'; then
    HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
    PRECOMMIT_SCRIPT="${HOOK_DIR}/pre-commit-guard.sh"
    if [[ -f "$PRECOMMIT_SCRIPT" ]]; then
      PRECOMMIT_EXIT=0
      PRECOMMIT_OUTPUT=$(VIBEGUARD_DIR="${VIBEGUARD_DIR:-$(cd "$HOOK_DIR/.." && pwd)}" bash "$PRECOMMIT_SCRIPT" 2>&1) || PRECOMMIT_EXIT=$?
      if [[ $PRECOMMIT_EXIT -ne 0 ]]; then
        vg_log "pre-bash-guard" "Bash" "block" "pre-commit check failed" "$COMMAND"
        echo "$PRECOMMIT_OUTPUT" >&2
        cat <<BLOCK_EOF
{
  "decision": "block",
  "reason": "VIBEGUARD Pre-Commit 检查失败。请根据上方错误信息修复问题后重新提交。禁止使用环境变量绕过。"
}
BLOCK_EOF
        exit 0
      fi
    fi
  fi
fi

# --- doc-file-blocker：检测创建非标准 .md 文件 ---
# 允许的 .md 文件：README、CLAUDE、CONTRIBUTING、CHANGELOG、LICENSE、SKILL
if echo "$COMMAND_STRIPPED" | grep -qE "(cat|echo|printf|tee)\s.*>.*\.md\b" 2>/dev/null; then
  if ! echo "$COMMAND_STRIPPED" | grep -qiE "(README|CLAUDE|CONTRIBUTING|CHANGELOG|LICENSE|SKILL)\.md" 2>/dev/null; then
    # 输出警告而非阻止（可能是合理的文档创建）
    vg_log "pre-bash-guard" "Bash" "warn" "非标准 .md 文件" "$COMMAND"
    cat <<WARN_EOF
{
  "decision": "warn",
  "reason": "VIBEGUARD 警告：检测到创建非标准 .md 文件。只允许创建 README/CLAUDE/CONTRIBUTING/CHANGELOG/LICENSE/SKILL.md。如果确实需要，请确认文件用途。"
}
WARN_EOF
    exit 0
  fi
fi

# 通过所有检查 → 放行
vg_log "pre-bash-guard" "Bash" "pass" "" "$COMMAND"
exit 0

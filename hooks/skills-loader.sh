#!/usr/bin/env bash
# VibeGuard Skills Loader — 会话首次工具调用时加载匹配 Skill
#
# 挂在 PreToolUse(Read) 上，每会话只触发一次。
# 扫描 ~/.claude/skills/ 和 .claude/skills/ 中的 SKILL.md，
# 按项目语言和当前目录匹配，输出相关 Skill 摘要。
#
# exit 0 = 始终放行（不阻止操作）
set -euo pipefail

# 每会话只运行一次：检查标志文件
SESSION_FLAG="${HOME}/.vibeguard/.skills_loaded_${VIBEGUARD_SESSION_ID:-$$}"

if [[ -f "$SESSION_FLAG" ]]; then
  exit 0
fi

# 标记已加载
mkdir -p "$(dirname "$SESSION_FLAG")"
touch "$SESSION_FLAG"

# 清理过期标志文件（>24h）
find "${HOME}/.vibeguard/" -name ".skills_loaded_*" -mtime +1 -delete 2>/dev/null || true

# 收集 Skill 目录
SKILL_DIRS=()
[[ -d "${HOME}/.claude/skills" ]] && SKILL_DIRS+=("${HOME}/.claude/skills")
[[ -d ".claude/skills" ]] && SKILL_DIRS+=(".claude/skills")

if [[ ${#SKILL_DIRS[@]} -eq 0 ]]; then
  exit 0
fi

# 检测当前项目语言（快速检查）
LANGS=""
[[ -f "Cargo.toml" ]] && LANGS="${LANGS}rust "
[[ -f "pyproject.toml" || -f "requirements.txt" ]] && LANGS="${LANGS}python "
[[ -f "tsconfig.json" ]] && LANGS="${LANGS}typescript "
[[ -f "package.json" ]] && LANGS="${LANGS}javascript "
[[ -f "go.mod" ]] && LANGS="${LANGS}go "

# 搜索匹配的 Skill
MATCHES=$(python3 -c "
import os, sys, re

skill_dirs = '${SKILL_DIRS[*]}'.split()
langs = '${LANGS}'.split()
cwd = os.getcwd()
cwd_name = os.path.basename(cwd)

matches = []

for skill_dir in skill_dirs:
    if not os.path.isdir(skill_dir):
        continue
    for entry in os.listdir(skill_dir):
        skill_path = os.path.join(skill_dir, entry, 'SKILL.md')
        if not os.path.isfile(skill_path):
            # 也检查直接的 .md 文件
            skill_path = os.path.join(skill_dir, entry)
            if not skill_path.endswith('.md') or not os.path.isfile(skill_path):
                continue

        try:
            with open(skill_path) as f:
                content = f.read(2000)  # 只读前 2000 字符
        except (OSError, UnicodeDecodeError):
            continue

        # 提取 frontmatter
        name = ''
        description = ''
        fm_match = re.search(r'^---\n(.*?)\n---', content, re.DOTALL)
        if fm_match:
            fm = fm_match.group(1)
            name_match = re.search(r'^name:\s*(.+)', fm, re.MULTILINE)
            desc_match = re.search(r'^description:\s*[|>]?\s*\n?\s*(.+)', fm, re.MULTILINE)
            if name_match:
                name = name_match.group(1).strip().strip('\"')
            if desc_match:
                description = desc_match.group(1).strip().strip('\"')

        if not name:
            continue

        # 匹配规则：语言、项目名、关键词
        content_lower = content.lower()
        score = 0

        # 语言匹配
        for lang in langs:
            if lang.lower() in content_lower:
                score += 2

        # 项目名匹配
        if cwd_name.lower() in content_lower:
            score += 3

        # 触发条件中的关键词匹配
        trigger_section = ''
        trigger_match = re.search(r'##\s*(Context|Trigger)', content, re.IGNORECASE)
        if trigger_match:
            start = trigger_match.start()
            next_section = re.search(r'\n##\s', content[start+10:])
            end = start + 10 + next_section.start() if next_section else len(content)
            trigger_section = content[start:end].lower()

        if score > 0:
            matches.append((score, name, description[:100]))

# 按分数排序，输出 top 5
matches.sort(key=lambda x: -x[0])
for score, name, desc in matches[:5]:
    print(f'{name}: {desc}')
" 2>/dev/null || true)

if [[ -z "$MATCHES" ]]; then
  exit 0
fi

MATCH_COUNT=$(echo "$MATCHES" | wc -l | tr -d ' ')

# 输出匹配的 Skill（作为 hook 反馈注入会话）
echo "[VibeGuard Skills] 检测到 ${MATCH_COUNT} 个相关 Skill："
echo "$MATCHES" | while IFS= read -r line; do
  echo "  - ${line}"
done
echo "使用 /skill-name 调用，或忽略此提示继续工作。"

exit 0

#!/usr/bin/env bash
# VibeGuard Skills Loader — 可选的 Skill/学习提示加载器
#
# 默认不注册；如需启用，可手动挂在 PreToolUse(Read) 上，每会话只触发一次。
# 扫描 ~/.claude/skills/ 和 .claude/skills/ 中的 SKILL.md，
# 按项目语言和当前目录匹配，输出相关 Skill 摘要。
#
# exit 0 = 始终放行（不阻止操作）
set -euo pipefail

# 共享 session ID（source log.sh 获取稳定的 VIBEGUARD_SESSION_ID）
_VG_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "${_VG_SCRIPT_DIR}/log.sh" ]]; then
  source "${_VG_SCRIPT_DIR}/log.sh"
elif [[ -n "${VIBEGUARD_DIR:-}" ]] && [[ -f "${VIBEGUARD_DIR}/hooks/log.sh" ]]; then
  source "${VIBEGUARD_DIR}/hooks/log.sh"
fi

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

# ── 学习信号推荐（消费 learn-digest.jsonl，水位线去重） ──
DIGEST_FILE="${HOME}/.vibeguard/learn-digest.jsonl"
WATERMARK_FILE="${HOME}/.vibeguard/.learn-watermark"

LEARN_HINTS=$(python3 -c "
import json, os, sys

digest = '${DIGEST_FILE}'
watermark = '${WATERMARK_FILE}'

if not os.path.exists(digest):
    sys.exit(0)

# 读水位线
last_ts = ''
if os.path.exists(watermark):
    with open(watermark) as f:
        last_ts = f.read().strip()

# 读取水位线之后的新信号
new_signals = []
latest_ts = last_ts
with open(digest) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        ts = entry.get('ts', '')
        if ts <= last_ts:
            continue
        if ts > latest_ts:
            latest_ts = ts
        for sig in entry.get('signals', []):
            sig['project'] = entry.get('project', '')
            new_signals.append(sig)

if not new_signals:
    sys.exit(0)

# 按类型汇总，最多输出 5 条
type_labels = {
    'repeated_warn': '高频警告',
    'chronic_block': '反复拦截',
    'hot_files': '热点文件',
    'slow_sessions': '慢操作密集',
    'warn_escalation': '警告趋势上升',
    'linter_violations': '代码违规',
}
output = []
for sig in new_signals[:5]:
    t = type_labels.get(sig['type'], sig['type'])
    src = '[扫描]' if sig.get('source') == 'code_scan' else '[日志]'
    if sig['type'] == 'linter_violations':
        detail = sig.get('guard', '')
        count = sig.get('count', '')
    else:
        detail = sig.get('reason', sig.get('file', ''))
        count = sig.get('count', sig.get('edits', ''))
    if detail and len(detail) > 55:
        detail = '...' + detail[-52:]
    output.append(f'{src} {t}: {detail} ({count}次)')

# 更新水位线
with open(watermark, 'w') as f:
    f.write(latest_ts)

for line in output:
    print(line)
" 2>/dev/null || true)

# 输出
HAS_OUTPUT=false

if [[ -n "$LEARN_HINTS" ]]; then
  HAS_OUTPUT=true
  HINT_COUNT=$(echo "$LEARN_HINTS" | wc -l | tr -d ' ')
  echo "[VibeGuard 学习推荐] 检测到 ${HINT_COUNT} 个跨会话学习信号："
  echo "$LEARN_HINTS" | while IFS= read -r line; do
    echo "  - ${line}"
  done
  echo "运行 /vibeguard:learn 可从这些信号中提取守卫规则或 Skill。"
  echo
fi

if [[ -n "$MATCHES" ]]; then
  HAS_OUTPUT=true
  MATCH_COUNT=$(echo "$MATCHES" | wc -l | tr -d ' ')
  echo "[VibeGuard Skills] 检测到 ${MATCH_COUNT} 个相关 Skill："
  echo "$MATCHES" | while IFS= read -r line; do
    echo "  - ${line}"
  done
  echo "使用 /skill-name 调用，或忽略此提示继续工作。"
fi

exit 0

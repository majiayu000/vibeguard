#!/usr/bin/env bash
# VibeGuard Skills Loader — Optional Skill/Learning Tips Loader
#
# Not registered by default; if you need to enable it, you can manually hang it on PreToolUse(Read), which is only triggered once per session.
# Scan ~/.claude/skills/ and .claude/skills/ for SKILL.md,
# Match the project language and current directory and output the relevant Skill summary.
#
# exit 0 = always let (do not block operation)
set -euo pipefail

# Share session ID (source log.sh to obtain stable VIBEGUARD_SESSION_ID)
_VG_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "${_VG_SCRIPT_DIR}/log.sh" ]]; then
  source "${_VG_SCRIPT_DIR}/log.sh"
elif [[ -n "${VIBEGUARD_DIR:-}" ]] && [[ -f "${VIBEGUARD_DIR}/hooks/log.sh" ]]; then
  source "${VIBEGUARD_DIR}/hooks/log.sh"
fi

# Run only once per session: check flags file
SESSION_FLAG="${HOME}/.vibeguard/.skills_loaded_${VIBEGUARD_SESSION_ID:-$$}"

if [[ -f "$SESSION_FLAG" ]]; then
  exit 0
fi

# mark loaded
mkdir -p "$(dirname "$SESSION_FLAG")"
touch "$SESSION_FLAG"

# Clean up expired flag files (>24h)
find "${HOME}/.vibeguard/" -name ".skills_loaded_*" -mtime +1 -delete 2>/dev/null || true

# Collect Skill directory
SKILL_DIRS=()
[[ -d "${HOME}/.claude/skills" ]] && SKILL_DIRS+=("${HOME}/.claude/skills")
[[ -d ".claude/skills" ]] && SKILL_DIRS+=(".claude/skills")

if [[ ${#SKILL_DIRS[@]} -eq 0 ]]; then
  exit 0
fi

# Detect current project language (quick check)
LANGS=""
[[ -f "Cargo.toml" ]] && LANGS="${LANGS}rust "
[[ -f "pyproject.toml" || -f "requirements.txt" ]] && LANGS="${LANGS}python "
[[ -f "tsconfig.json" ]] && LANGS="${LANGS}typescript "
[[ -f "package.json" ]] && LANGS="${LANGS}javascript "
[[ -f "go.mod" ]] && LANGS="${LANGS}go "

# Search for matching Skills
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
            # Also check direct .md files
            skill_path = os.path.join(skill_dir, entry)
            if not skill_path.endswith('.md') or not os.path.isfile(skill_path):
                continue

        try:
            with open(skill_path) as f:
                content = f.read(2000) # Read only the first 2000 characters
        except (OSError, UnicodeDecodeError):
            continue

        # Extract frontmatter
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

        # Matching rules: language, project name, keywords
        content_lower = content.lower()
        score = 0

        # Language matching
        for lang in langs:
            if lang.lower() in content_lower:
                score += 2

        # Project name match
        if cwd_name.lower() in content_lower:
            score += 3

        # Keyword matching in trigger conditions
        trigger_section = ''
        trigger_match = re.search(r'##\s*(Context|Trigger)', content, re.IGNORECASE)
        if trigger_match:
            start = trigger_match.start()
            next_section = re.search(r'\n##\s', content[start+10:])
            end = start + 10 + next_section.start() if next_section else len(content)
            trigger_section = content[start:end].lower()

        if score > 0:
            matches.append((score, name, description[:100]))

# Sort by score and output top 5
matches.sort(key=lambda x: -x[0])
for score, name, desc in matches[:5]:
    print(f'{name}: {desc}')
" 2>/dev/null || true)

# ── Learning signal recommendation (consume learn-digest.jsonl, water level deduplication) ──
DIGEST_FILE="${HOME}/.vibeguard/learn-digest.jsonl"
WATERMARK_FILE="${HOME}/.vibeguard/.learn-watermark"

LEARN_HINTS=$(python3 -c "
import json, os, sys

digest = '${DIGEST_FILE}'
watermark = '${WATERMARK_FILE}'

if not os.path.exists(digest):
    sys.exit(0)

# Read water level
last_ts = ''
if os.path.exists(watermark):
    with open(watermark) as f:
        last_ts = f.read().strip()

# Read the new signal after the water mark
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

# Summarize by type, output up to 5 items
type_labels = {
    'repeated_warn': 'High frequency warning',
    'chronic_block': 'Repeated interception',
    'hot_files': 'hot files',
    'slow_sessions': 'Slow operation intensive',
    'warn_escalation': 'Warning trend rising',
    'linter_violations': 'Code violations',
}
output = []
for sig in new_signals[:5]:
    t = type_labels.get(sig['type'], sig['type'])
    src = '[scan]' if sig.get('source') == 'code_scan' else '[log]'
    if sig['type'] == 'linter_violations':
        detail = sig.get('guard', '')
        count = sig.get('count', '')
    else:
        detail = sig.get('reason', sig.get('file', ''))
        count = sig.get('count', sig.get('edits', ''))
    if detail and len(detail) > 55:
        detail = '...' + detail[-52:]
    output.append(f'{src} {t}: {detail} ({count} times)')

# Update water level
with open(watermark, 'w') as f:
    f.write(latest_ts)

for line in output:
    print(line)
" 2>/dev/null || true)

# output
HAS_OUTPUT=false

if [[ -n "$LEARN_HINTS" ]]; then
  HAS_OUTPUT=true
  HINT_COUNT=$(echo "$LEARN_HINTS" | wc -l | tr -d ' ')
  echo "[VibeGuard Learning Recommendations] ${HINT_COUNT} cross-session learning signals detected:"
  echo "$LEARN_HINTS" | while IFS= read -r line; do
    echo "  - ${line}"
  done
  echo "Run /vibeguard:learn to extract guard rules or skills from these signals."
  echo
fi

if [[ -n "$MATCHES" ]]; then
  HAS_OUTPUT=true
  MATCH_COUNT=$(echo "$MATCHES" | wc -l | tr -d ' ')
  echo "[VibeGuard Skills] detected ${MATCH_COUNT} related Skills:"
  echo "$MATCHES" | while IFS= read -r line; do
    echo "  - ${line}"
  done
  echo "Invoke with /skill-name, or ignore this prompt and continue working."
fi

exit 0

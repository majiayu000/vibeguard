#!/usr/bin/env bash
set -euo pipefail

# VibeGuard Setup Script
# 一键部署防幻觉规范到 ~/.claude/ 和 ~/.codex/
#
# 使用方法：
#   bash setup.sh          # 安装
#   bash setup.sh --check  # 仅检查状态
#   bash setup.sh --clean  # 清理安装

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
CODEX_DIR="${HOME}/.codex"

# 颜色输出
green() { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
red() { printf '\033[31m%s\033[0m\n' "$1"; }

# 创建 symlink，处理已有目录的情况
# ln -sfn 在目标是已有目录时会在内部创建 symlink 而非替换
safe_symlink() {
  local src="$1"
  local dst="$2"
  if [[ -d "${dst}" && ! -L "${dst}" ]]; then
    # 非空真实目录：拒绝覆盖，避免误删用户数据
    if [[ -n "$(ls -A "${dst}" 2>/dev/null)" ]]; then
      red "  ERROR: ${dst} is a non-empty directory, refusing to overwrite."
      red "  Please remove or rename it manually, then re-run setup.sh."
      return 1
    fi
    rmdir "${dst}"
  fi
  ln -sfn "${src}" "${dst}"
}

# --- Check Mode ---
if [[ "${1:-}" == "--check" ]]; then
  echo "VibeGuard Installation Status"
  echo "=============================="

  # Check CLAUDE.md
  if [[ -f "${CLAUDE_DIR}/CLAUDE.md" ]] && grep -q "VibeGuard" "${CLAUDE_DIR}/CLAUDE.md" 2>/dev/null; then
    green "[OK] VibeGuard rules in ~/.claude/CLAUDE.md"
  else
    red "[MISSING] VibeGuard rules not in ~/.claude/CLAUDE.md"
  fi

  # Check Claude Code skills
  for skill in vibeguard auto-optimize; do
    if [[ -L "${CLAUDE_DIR}/skills/${skill}" ]]; then
      green "[OK] ${skill} skill symlinked to ~/.claude/skills/"
    else
      red "[MISSING] ${skill} skill not in ~/.claude/skills/"
    fi
  done

  # Check custom commands
  if [[ -L "${CLAUDE_DIR}/commands/vibeguard" ]]; then
    green "[OK] vibeguard commands symlinked to ~/.claude/commands/"
  else
    red "[MISSING] vibeguard commands not in ~/.claude/commands/"
  fi

  # Check Codex skills
  for skill in plan-folw fixflow optflow plan-mode vibeguard auto-optimize; do
    if [[ -L "${CODEX_DIR}/skills/${skill}" ]]; then
      green "[OK] ${skill} skill symlinked to ~/.codex/skills/"
    else
      yellow "[MISSING] ${skill} skill not in ~/.codex/skills/"
    fi
  done

  # Check AUTO_RUN_AGENT_DIR
  if [[ -n "${AUTO_RUN_AGENT_DIR:-}" ]] && [[ -d "${AUTO_RUN_AGENT_DIR}" ]]; then
    green "[OK] AUTO_RUN_AGENT_DIR=${AUTO_RUN_AGENT_DIR}"
  else
    yellow "[INFO] AUTO_RUN_AGENT_DIR not set (auto-optimize Phase 4 requires it)"
  fi

  # Check MCP Server
  if [[ -f "${REPO_DIR}/mcp-server/dist/index.js" ]]; then
    green "[OK] MCP Server built"
  else
    red "[MISSING] MCP Server not built (run setup.sh to build)"
  fi

  # Check MCP Server config in settings.json
  SETTINGS_FILE="${CLAUDE_DIR}/settings.json"
  if [[ -f "${SETTINGS_FILE}" ]] && python3 -c "
import json, sys
with open('${SETTINGS_FILE}') as f:
    data = json.load(f)
sys.exit(0 if 'vibeguard' in data.get('mcpServers', {}) else 1)
" 2>/dev/null; then
    green "[OK] MCP Server configured in settings.json"
  else
    red "[MISSING] MCP Server not in settings.json"
  fi

  # Check Hooks config
  if [[ -f "${SETTINGS_FILE}" ]] && python3 -c "
import json, sys
with open('${SETTINGS_FILE}') as f:
    data = json.load(f)
hooks = data.get('hooks', {}).get('PreToolUse', [])
has_write = any('pre-write-guard' in str(h) for h in hooks)
has_bash = any('pre-bash-guard' in str(h) for h in hooks)
sys.exit(0 if (has_write and has_bash) else 1)
" 2>/dev/null; then
    green "[OK] PreToolUse hooks configured (Write block + Bash block)"
  else
    yellow "[MISSING] PreToolUse hooks not fully configured"
  fi

  if [[ -f "${SETTINGS_FILE}" ]] && python3 -c "
import json, sys
with open('${SETTINGS_FILE}') as f:
    data = json.load(f)
hooks = data.get('hooks', {}).get('PostToolUse', [])
has_guard = any('post-guard-check' in str(h) for h in hooks)
has_edit = any('post-edit-guard' in str(h) for h in hooks)
sys.exit(0 if (has_guard and has_edit) else 1)
" 2>/dev/null; then
    green "[OK] PostToolUse hooks configured (guard_check + Edit quality)"
  else
    yellow "[MISSING] PostToolUse hooks not fully configured"
  fi

  exit 0
fi

# --- Clean Mode ---
if [[ "${1:-}" == "--clean" ]]; then
  echo "Cleaning VibeGuard installation..."

  # Remove CLAUDE.md VibeGuard section (marker-based, safe)
  if [[ -f "${CLAUDE_DIR}/CLAUDE.md" ]]; then
    python3 -c "
from pathlib import Path

claude_md = Path('${CLAUDE_DIR}/CLAUDE.md')
content = claude_md.read_text()

START = '<!-- vibeguard-start -->'
END = '<!-- vibeguard-end -->'
start_idx = content.find(START)
end_idx = content.find(END)

if start_idx >= 0 and end_idx >= 0:
    before = content[:start_idx].rstrip()
    after = content[end_idx + len(END):].lstrip('\n')
    content = before
    if after:
        content += '\n\n' + after
    content = content.rstrip() + '\n'
    claude_md.write_text(content)
    print('REMOVED')
else:
    # Legacy fallback: remove from '# VibeGuard' to end
    marker = '\n# VibeGuard'
    idx = content.find(marker)
    if idx >= 0:
        content = content[:idx].rstrip() + '\n'
        claude_md.write_text(content)
        print('REMOVED_LEGACY')
    else:
        print('NOT_FOUND')
" 2>/dev/null && yellow "Removed VibeGuard rules from ~/.claude/CLAUDE.md" || true
  fi

  # Remove symlinks
  rm -f "${CLAUDE_DIR}/commands/vibeguard" 2>/dev/null || rm -rf "${CLAUDE_DIR}/commands/vibeguard" 2>/dev/null || true
  rm -f "${CLAUDE_DIR}/skills/vibeguard"
  rm -f "${CLAUDE_DIR}/skills/auto-optimize"
  for skill in plan-folw fixflow optflow plan-mode vibeguard auto-optimize; do
    rm -f "${CODEX_DIR}/skills/${skill}"
  done

  # Remove MCP Server config and Hooks from settings.json
  SETTINGS_FILE="${CLAUDE_DIR}/settings.json"
  if [[ -f "${SETTINGS_FILE}" ]]; then
    python3 -c "
import json

with open('${SETTINGS_FILE}') as f:
    data = json.load(f)

changed = False

# Remove MCP Server
if 'vibeguard' in data.get('mcpServers', {}):
    del data['mcpServers']['vibeguard']
    if not data['mcpServers']:
        del data['mcpServers']
    changed = True

# Remove PreToolUse hooks (pre-write-guard + pre-bash-guard)
if 'hooks' in data and 'PreToolUse' in data['hooks']:
    original = data['hooks']['PreToolUse']
    filtered = [h for h in original if not any(
        k in json.dumps(h) for k in ['pre-write-guard', 'pre-bash-guard']
    )]
    if len(filtered) != len(original):
        data['hooks']['PreToolUse'] = filtered
        if not filtered:
            del data['hooks']['PreToolUse']
        changed = True

# Remove PostToolUse hooks (post-guard-check + post-edit-guard)
if 'hooks' in data and 'PostToolUse' in data['hooks']:
    original = data['hooks']['PostToolUse']
    filtered = [h for h in original if not any(
        k in json.dumps(h) for k in ['post-guard-check', 'post-edit-guard']
    )]
    if len(filtered) != len(original):
        data['hooks']['PostToolUse'] = filtered
        if not filtered:
            del data['hooks']['PostToolUse']
        changed = True

if 'hooks' in data and not data['hooks']:
    del data['hooks']

if changed:
    with open('${SETTINGS_FILE}', 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write('\n')
" 2>/dev/null && yellow "Removed MCP Server and Hooks from settings.json" || true
  fi

  green "VibeGuard cleaned."
  exit 0
fi

# --- Install Mode ---
echo "=============================="
echo "VibeGuard Setup"
echo "Repository: ${REPO_DIR}"
echo "=============================="
echo

# 1. 确保目录存在
echo "Step 1: Prepare directories"
mkdir -p "${CLAUDE_DIR}"
green "  ~/.claude/ ready"
echo

# 2. Symlink skills 到 Claude Code
echo "Step 2: Install Claude Code skills"
mkdir -p "${CLAUDE_DIR}/skills"

safe_symlink "${REPO_DIR}/skills/vibeguard" "${CLAUDE_DIR}/skills/vibeguard"
green "  vibeguard -> ~/.claude/skills/vibeguard"

safe_symlink "${REPO_DIR}/workflows/auto-optimize" "${CLAUDE_DIR}/skills/auto-optimize"
green "  auto-optimize -> ~/.claude/skills/auto-optimize"
echo

# 3. Install custom commands
echo "Step 3: Install custom commands"
mkdir -p "${CLAUDE_DIR}/commands"

safe_symlink "${REPO_DIR}/.claude/commands/vibeguard" "${CLAUDE_DIR}/commands/vibeguard"
green "  /vibeguard:preflight, /vibeguard:check, /vibeguard:learn -> ~/.claude/commands/vibeguard"
echo

# 4. Symlink workflow skills 到 Codex
echo "Step 4: Install Codex skills"
mkdir -p "${CODEX_DIR}/skills"

for skill in plan-folw fixflow optflow plan-mode auto-optimize; do
  safe_symlink "${REPO_DIR}/workflows/${skill}" "${CODEX_DIR}/skills/${skill}"
  green "  ${skill} -> ~/.codex/skills/${skill}"
done

# Also link vibeguard to Codex
safe_symlink "${REPO_DIR}/skills/vibeguard" "${CODEX_DIR}/skills/vibeguard"
green "  vibeguard -> ~/.codex/skills/vibeguard"
echo

# 5. 检测 auto-run-agent 环境变量
echo "Step 5: Check auto-run-agent"
if [[ -n "${AUTO_RUN_AGENT_DIR:-}" ]] && [[ -d "${AUTO_RUN_AGENT_DIR}" ]]; then
  green "  AUTO_RUN_AGENT_DIR=${AUTO_RUN_AGENT_DIR}"
else
  yellow "  AUTO_RUN_AGENT_DIR not set (optional, needed for auto-optimize Phase 4)"
  yellow "  To set: export AUTO_RUN_AGENT_DIR=/path/to/auto-run-agent"
fi
echo

# 6. Build MCP Server
echo "Step 6: Build MCP Server"
if ! command -v node &>/dev/null; then
  yellow "  Node.js not found, skipping MCP Server build"
  yellow "  Install Node.js >= 18 to enable MCP Server"
elif [[ -f "${REPO_DIR}/mcp-server/dist/index.js" ]] && \
     [[ "${REPO_DIR}/mcp-server/dist/index.js" -nt "${REPO_DIR}/mcp-server/src/index.ts" ]]; then
  yellow "  MCP Server already built and up to date, skipping"
else
  (cd "${REPO_DIR}/mcp-server" && npm install --silent && npm run build --silent) 2>&1
  green "  MCP Server built successfully"
fi
echo

# 7. Configure MCP Server + Hooks in settings.json
echo "Step 7: Configure MCP Server + Hooks"
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"

python3 -c "
import json
from pathlib import Path

settings_path = Path('${SETTINGS_FILE}')
repo_dir = '${REPO_DIR}'

# Load existing or create empty
if settings_path.exists():
    with open(settings_path) as f:
        data = json.load(f)
else:
    data = {}

changed = False

# Add MCP Server config
if 'mcpServers' not in data:
    data['mcpServers'] = {}
if 'vibeguard' not in data['mcpServers']:
    data['mcpServers']['vibeguard'] = {
        'type': 'stdio',
        'command': 'node',
        'args': [f'{repo_dir}/mcp-server/dist/index.js']
    }
    changed = True

# Add PreToolUse hook
if 'hooks' not in data:
    data['hooks'] = {}
if 'PreToolUse' not in data['hooks']:
    data['hooks']['PreToolUse'] = []

has_vibeguard_hook = any(
    'pre-write-guard' in json.dumps(h)
    for h in data['hooks']['PreToolUse']
)
if not has_vibeguard_hook:
    data['hooks']['PreToolUse'].append({
        'matcher': 'Write',
        'hooks': [{
            'type': 'command',
            'command': f'bash {repo_dir}/hooks/pre-write-guard.sh'
        }]
    })
    changed = True

# Add PreToolUse hook for Bash (dangerous command blocking)
has_bash_hook = any(
    'pre-bash-guard' in json.dumps(h)
    for h in data['hooks']['PreToolUse']
)
if not has_bash_hook:
    data['hooks']['PreToolUse'].append({
        'matcher': 'Bash',
        'hooks': [{
            'type': 'command',
            'command': f'bash {repo_dir}/hooks/pre-bash-guard.sh'
        }]
    })
    changed = True

# Add PostToolUse hook for guard_check
if 'PostToolUse' not in data['hooks']:
    data['hooks']['PostToolUse'] = []

has_post_guard_hook = any(
    'post-guard-check' in json.dumps(h)
    for h in data['hooks']['PostToolUse']
)
if not has_post_guard_hook:
    data['hooks']['PostToolUse'].append({
        'matcher': 'mcp__vibeguard__guard_check',
        'hooks': [{
            'type': 'command',
            'command': f'bash {repo_dir}/hooks/post-guard-check.sh'
        }]
    })
    changed = True

# Add PostToolUse hook for Edit (quality warnings)
has_edit_hook = any(
    'post-edit-guard' in json.dumps(h)
    for h in data['hooks']['PostToolUse']
)
if not has_edit_hook:
    data['hooks']['PostToolUse'].append({
        'matcher': 'Edit',
        'hooks': [{
            'type': 'command',
            'command': f'bash {repo_dir}/hooks/post-edit-guard.sh'
        }]
    })
    changed = True

if changed:
    with open(settings_path, 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write('\n')
    print('CHANGED')
else:
    print('SKIP')
" 2>/dev/null

if [[ $? -eq 0 ]]; then
  green "  MCP Server + Hooks configured in ~/.claude/settings.json"
else
  red "  Failed to configure settings.json"
fi
echo

# 8. Re-inject CLAUDE.md (in case rules were updated)
echo "Step 8: Update VibeGuard rules in CLAUDE.md"
RULES_FILE="${REPO_DIR}/claude-md/vibeguard-rules.md"

python3 -c "
from pathlib import Path

claude_md = Path('${CLAUDE_DIR}/CLAUDE.md')
rules = Path('${RULES_FILE}').read_text()

if claude_md.exists():
    content = claude_md.read_text()
else:
    content = ''

START = '<!-- vibeguard-start -->'
END = '<!-- vibeguard-end -->'

start_idx = content.find(START)
end_idx = content.find(END)

if start_idx >= 0 and end_idx >= 0:
    # Replace existing block (preserve content before and after)
    before = content[:start_idx].rstrip()
    after = content[end_idx + len(END):].lstrip('\n')
    content = before + '\n\n' + rules.strip() + '\n'
    if after:
        content += '\n' + after
    action = 'UPDATED'
else:
    # Append (no existing block or legacy format without markers)
    # Also handle legacy format: remove from '# VibeGuard' to end if no markers
    legacy_marker = '\n# VibeGuard'
    legacy_idx = content.find(legacy_marker)
    if legacy_idx >= 0:
        content = content[:legacy_idx].rstrip()
    content = content.rstrip() + '\n\n' + rules.strip() + '\n'
    action = 'APPENDED'

claude_md.write_text(content)
print(action)
" 2>/dev/null

if [[ $? -eq 0 ]]; then
  green "  VibeGuard rules synced to ~/.claude/CLAUDE.md"
else
  red "  Failed to update CLAUDE.md"
fi
echo

# 8. 验证
echo "=============================="
echo "Verification"
echo "=============================="

errors=0

for skill in vibeguard auto-optimize; do
  if [[ -L "${CLAUDE_DIR}/skills/${skill}" ]]; then
    green "[OK] Claude Code: ${skill} skill"
  else
    red "[FAIL] Claude Code: ${skill} skill"
    ((errors++))
  fi
done

if [[ -L "${CLAUDE_DIR}/commands/vibeguard" ]]; then
  green "[OK] Custom commands: /vibeguard:preflight, /vibeguard:check, /vibeguard:learn"
else
  red "[FAIL] Custom commands not installed"
  ((errors++))
fi

for skill in plan-folw fixflow optflow plan-mode vibeguard auto-optimize; do
  if [[ -L "${CODEX_DIR}/skills/${skill}" ]]; then
    green "[OK] Codex: ${skill} skill"
  else
    red "[FAIL] Codex: ${skill} skill"
    ((errors++))
  fi
done

if grep -q "VibeGuard" "${CLAUDE_DIR}/CLAUDE.md" 2>/dev/null; then
  green "[OK] VibeGuard rules in CLAUDE.md"
else
  red "[FAIL] VibeGuard rules not in CLAUDE.md"
  ((errors++))
fi

if [[ -f "${REPO_DIR}/mcp-server/dist/index.js" ]]; then
  green "[OK] MCP Server built"
else
  red "[FAIL] MCP Server not built"
  ((errors++))
fi

if [[ -f "${SETTINGS_FILE}" ]] && python3 -c "
import json, sys
with open('${SETTINGS_FILE}') as f:
    data = json.load(f)
sys.exit(0 if 'vibeguard' in data.get('mcpServers', {}) else 1)
" 2>/dev/null; then
  green "[OK] MCP Server in settings.json"
else
  red "[FAIL] MCP Server not in settings.json"
  ((errors++))
fi

echo
if [[ ${errors} -eq 0 ]]; then
  green "Setup complete! All components installed."
  echo
  echo "Next steps:"
  echo "  1. Open a new Claude Code session to verify rules are active"
  echo "  2. Run: /vibeguard:preflight <project_dir> — 修改前生成约束集（预防）"
  echo "  3. Run: /vibeguard:check <project_dir> — 修改后运行守卫检查（验证）"
  echo "  4. Run: /auto-optimize <project_dir> — 自主优化项目"
  echo "  5. MCP Tools: guard_check, compliance_report, metrics_collect"
else
  red "Setup completed with ${errors} errors."
  exit 1
fi

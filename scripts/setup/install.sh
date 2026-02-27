#!/usr/bin/env bash
set -euo pipefail

# VibeGuard Setup Script
# 一键部署防幻觉规范到 ~/.claude/ 和 ~/.codex/
#
# 使用方法：
#   bash setup.sh          # 安装
#   bash setup.sh --check  # 仅检查状态
#   bash setup.sh --clean  # 清理安装

REPO_DIR="${VIBEGUARD_REPO_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
CLAUDE_DIR="${HOME}/.claude"
CODEX_DIR="${HOME}/.codex"
SETTINGS_HELPER="${REPO_DIR}/scripts/lib/settings_json.py"

# 颜色输出
green() { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
red() { printf '\033[31m%s\033[0m\n' "$1"; }

settings_check() {
  local settings_file="$1"
  local target="$2"
  [[ -f "${settings_file}" ]] || return 1
  python3 "${SETTINGS_HELPER}" check --settings-file "${settings_file}" --target "${target}" >/dev/null 2>&1
}

settings_upsert() {
  local settings_file="$1"
  python3 "${SETTINGS_HELPER}" upsert-vibeguard --settings-file "${settings_file}" --repo-dir "${REPO_DIR}"
}

settings_remove() {
  local settings_file="$1"
  python3 "${SETTINGS_HELPER}" remove-vibeguard --settings-file "${settings_file}"
}

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
  for skill in vibeguard auto-optimize strategic-compact eval-harness iterative-retrieval; do
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

  # Check agents
  if [[ -d "${CLAUDE_DIR}/agents" ]] && [[ -n "$(ls -A "${CLAUDE_DIR}/agents" 2>/dev/null)" ]]; then
    agent_count=$(ls "${CLAUDE_DIR}/agents"/*.md 2>/dev/null | wc -l | tr -d ' ')
    green "[OK] ${agent_count} agents installed in ~/.claude/agents/"
  else
    yellow "[MISSING] agents not in ~/.claude/agents/"
  fi

  # Check context profiles
  if [[ -d "${CLAUDE_DIR}/context-profiles" ]] && [[ -n "$(ls -A "${CLAUDE_DIR}/context-profiles" 2>/dev/null)" ]]; then
    green "[OK] context profiles installed in ~/.claude/context-profiles/"
  else
    yellow "[MISSING] context profiles not in ~/.claude/context-profiles/"
  fi

  # Check Codex skills
for skill in plan-flow fixflow optflow plan-mode vibeguard auto-optimize; do
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

  # Check TypeScript guards
  for guard in check_any_abuse.sh check_console_residual.sh common.sh; do
    if [[ -x "${REPO_DIR}/guards/typescript/${guard}" ]]; then
      green "[OK] TypeScript guard: ${guard}"
    else
      red "[MISSING] TypeScript guard: ${guard}"
    fi
  done

  # Check MCP Server
  if [[ -f "${REPO_DIR}/mcp-server/dist/index.js" ]]; then
    green "[OK] MCP Server built"
  else
    red "[MISSING] MCP Server not built (run setup.sh to build)"
  fi

  # Check MCP Server config in settings.json
  SETTINGS_FILE="${CLAUDE_DIR}/settings.json"
  if settings_check "${SETTINGS_FILE}" "mcp"; then
    green "[OK] MCP Server configured in settings.json"
  else
    red "[MISSING] MCP Server not in settings.json"
  fi

  # Check Hooks config
  if settings_check "${SETTINGS_FILE}" "pre-hooks"; then
    green "[OK] PreToolUse hooks configured (Write block + Bash block + Edit guard)"
  else
    yellow "[MISSING] PreToolUse hooks not fully configured"
  fi

  if settings_check "${SETTINGS_FILE}" "post-hooks"; then
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
  rm -f "${CLAUDE_DIR}/skills/strategic-compact"
  rm -f "${CLAUDE_DIR}/skills/eval-harness"
  rm -f "${CLAUDE_DIR}/skills/iterative-retrieval"
  # Remove only files installed by VibeGuard, never delete user-owned directories wholesale
  for agent in "${REPO_DIR}"/agents/*.md; do
    [[ -f "$agent" ]] || continue
    rm -f "${CLAUDE_DIR}/agents/$(basename "$agent")"
  done
  rmdir "${CLAUDE_DIR}/agents" 2>/dev/null || true

  for profile in "${REPO_DIR}"/context-profiles/*.md; do
    [[ -f "$profile" ]] || continue
    rm -f "${CLAUDE_DIR}/context-profiles/$(basename "$profile")"
  done
  rmdir "${CLAUDE_DIR}/context-profiles" 2>/dev/null || true
  for skill in plan-flow fixflow optflow plan-mode vibeguard auto-optimize; do
    rm -f "${CODEX_DIR}/skills/${skill}"
  done

  # Remove MCP Server config and Hooks from settings.json
  SETTINGS_FILE="${CLAUDE_DIR}/settings.json"
  if [[ -f "${SETTINGS_FILE}" ]]; then
    if clean_result=$(settings_remove "${SETTINGS_FILE}" 2>/dev/null); then
      if [[ "${clean_result}" == "CHANGED" ]]; then
        yellow "Removed MCP Server and Hooks from settings.json"
      fi
    fi
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

# 检查 python3 是否可用（hooks 全部依赖 python3）
if ! command -v python3 &>/dev/null; then
  red "  ERROR: python3 not found. VibeGuard hooks require Python 3."
  red "  Install Python 3 and re-run setup.sh."
  exit 1
fi

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

# New skills from ECC
for skill in strategic-compact eval-harness iterative-retrieval; do
  safe_symlink "${REPO_DIR}/skills/${skill}" "${CLAUDE_DIR}/skills/${skill}"
  green "  ${skill} -> ~/.claude/skills/${skill}"
done
echo

# 2.5. Install agents
echo "Step 2.5: Install agents"
mkdir -p "${CLAUDE_DIR}/agents"
for agent in "${REPO_DIR}"/agents/*.md; do
  [[ -f "$agent" ]] || continue
  name=$(basename "$agent")
  cp "$agent" "${CLAUDE_DIR}/agents/${name}"
  green "  ${name} -> ~/.claude/agents/${name}"
done
echo

# 2.6. Install context profiles
echo "Step 2.6: Install context profiles"
mkdir -p "${CLAUDE_DIR}/context-profiles"
for profile in "${REPO_DIR}"/context-profiles/*.md; do
  [[ -f "$profile" ]] || continue
  name=$(basename "$profile")
  cp "$profile" "${CLAUDE_DIR}/context-profiles/${name}"
  green "  ${name} -> ~/.claude/context-profiles/${name}"
done
echo

# 3. Install custom commands
echo "Step 3: Install custom commands"
mkdir -p "${CLAUDE_DIR}/commands"

safe_symlink "${REPO_DIR}/.claude/commands/vibeguard" "${CLAUDE_DIR}/commands/vibeguard"
green "  /vibeguard:preflight, /vibeguard:check, /vibeguard:learn, /vibeguard:review, /vibeguard:cross-review, /vibeguard:build-fix, /vibeguard:interview -> ~/.claude/commands/vibeguard"
echo

# 4. Symlink workflow skills 到 Codex
echo "Step 4: Install Codex skills"
mkdir -p "${CODEX_DIR}/skills"

for skill in plan-flow fixflow optflow plan-mode auto-optimize; do
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
     ! find "${REPO_DIR}/mcp-server/src" -type f -name "*.ts" -newer "${REPO_DIR}/mcp-server/dist/index.js" | grep -q . && \
     [[ "${REPO_DIR}/mcp-server/package.json" -ot "${REPO_DIR}/mcp-server/dist/index.js" ]] && \
     [[ "${REPO_DIR}/mcp-server/tsconfig.json" -ot "${REPO_DIR}/mcp-server/dist/index.js" ]]; then
  yellow "  MCP Server already built and up to date, skipping"
else
  (cd "${REPO_DIR}/mcp-server" && npm install --silent && npm run build --silent) 2>&1
  green "  MCP Server built successfully"
fi
echo

# 7. Configure MCP Server + Hooks in settings.json
echo "Step 7: Configure MCP Server + Hooks"
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"

if settings_upsert "${SETTINGS_FILE}" >/dev/null 2>&1; then
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
"

if [[ $? -eq 0 ]]; then
  green "  VibeGuard rules synced to ~/.claude/CLAUDE.md"
else
  red "  Failed to update CLAUDE.md"
fi
echo

# 9. 验证
echo "Step 9: Verification"
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
  green "[OK] Custom commands: /vibeguard:preflight, /vibeguard:check, /vibeguard:learn, /vibeguard:review, /vibeguard:cross-review, /vibeguard:build-fix, /vibeguard:interview"
else
  red "[FAIL] Custom commands not installed"
  ((errors++))
fi

  for skill in plan-flow fixflow optflow plan-mode vibeguard auto-optimize; do
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

if settings_check "${SETTINGS_FILE}" "mcp"; then
  green "[OK] MCP Server in settings.json"
else
  red "[FAIL] MCP Server not in settings.json"
  ((errors++))
fi

# Check Codex CLI (optional, for cross-review)
if command -v codex &>/dev/null; then
  green "[OK] Codex CLI available (enables /vibeguard:cross-review)"
else
  yellow "[INFO] Codex CLI not found (install: npm i -g @openai/codex for /vibeguard:cross-review)"
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
  echo
  echo "Git Pre-Commit Guard:"
  echo "  在目标项目中安装: vibeguard install-hook <project_dir>"
  echo "  或手动: ln -sf ${REPO_DIR}/hooks/pre-commit-guard.sh <project>/.git/hooks/pre-commit"
else
  red "Setup completed with ${errors} errors."
  exit 1
fi

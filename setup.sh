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
    rm -rf "${dst}"
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

  exit 0
fi

# --- Clean Mode ---
if [[ "${1:-}" == "--clean" ]]; then
  echo "Cleaning VibeGuard installation..."

  # Remove CLAUDE.md VibeGuard section
  if [[ -f "${CLAUDE_DIR}/CLAUDE.md" ]]; then
    # Remove everything between VibeGuard markers
    if grep -q "# VibeGuard" "${CLAUDE_DIR}/CLAUDE.md"; then
      # Use sed to remove the VibeGuard block
      sed -i '' '/^# VibeGuard/,/^# [^V]/{ /^# [^V]/!d; }' "${CLAUDE_DIR}/CLAUDE.md" 2>/dev/null || true
      yellow "Removed VibeGuard rules from ~/.claude/CLAUDE.md (manual cleanup may be needed)"
    fi
  fi

  # Remove symlinks
  rm -f "${CLAUDE_DIR}/skills/vibeguard"
  rm -f "${CLAUDE_DIR}/skills/auto-optimize"
  for skill in plan-folw fixflow optflow plan-mode vibeguard auto-optimize; do
    rm -f "${CODEX_DIR}/skills/${skill}"
  done

  green "VibeGuard cleaned."
  exit 0
fi

# --- Install Mode ---
echo "=============================="
echo "VibeGuard Setup"
echo "Repository: ${REPO_DIR}"
echo "=============================="
echo

# 1. 追加 VibeGuard 规则到 ~/.claude/CLAUDE.md
echo "Step 1: Update ~/.claude/CLAUDE.md"
mkdir -p "${CLAUDE_DIR}"

if [[ -f "${CLAUDE_DIR}/CLAUDE.md" ]] && grep -q "VibeGuard" "${CLAUDE_DIR}/CLAUDE.md" 2>/dev/null; then
  yellow "  VibeGuard rules already present, skipping"
else
  echo "" >> "${CLAUDE_DIR}/CLAUDE.md"
  cat "${REPO_DIR}/claude-md/vibeguard-rules.md" >> "${CLAUDE_DIR}/CLAUDE.md"
  green "  Appended VibeGuard rules to ~/.claude/CLAUDE.md"
fi
echo

# 2. Symlink skills 到 Claude Code
echo "Step 2: Install Claude Code skills"
mkdir -p "${CLAUDE_DIR}/skills"

safe_symlink "${REPO_DIR}/skills/vibeguard" "${CLAUDE_DIR}/skills/vibeguard"
green "  vibeguard -> ~/.claude/skills/vibeguard"

safe_symlink "${REPO_DIR}/workflows/auto-optimize" "${CLAUDE_DIR}/skills/auto-optimize"
green "  auto-optimize -> ~/.claude/skills/auto-optimize"
echo

# 3. Symlink workflow skills 到 Codex
echo "Step 3: Install Codex skills"
mkdir -p "${CODEX_DIR}/skills"

for skill in plan-folw fixflow optflow plan-mode auto-optimize; do
  safe_symlink "${REPO_DIR}/workflows/${skill}" "${CODEX_DIR}/skills/${skill}"
  green "  ${skill} -> ~/.codex/skills/${skill}"
done

# Also link vibeguard to Codex
safe_symlink "${REPO_DIR}/skills/vibeguard" "${CODEX_DIR}/skills/vibeguard"
green "  vibeguard -> ~/.codex/skills/vibeguard"
echo

# 4. 检测 auto-run-agent 环境变量
echo "Step 4: Check auto-run-agent"
if [[ -n "${AUTO_RUN_AGENT_DIR:-}" ]] && [[ -d "${AUTO_RUN_AGENT_DIR}" ]]; then
  green "  AUTO_RUN_AGENT_DIR=${AUTO_RUN_AGENT_DIR}"
else
  yellow "  AUTO_RUN_AGENT_DIR not set (optional, needed for auto-optimize Phase 4)"
  yellow "  To set: export AUTO_RUN_AGENT_DIR=/path/to/auto-run-agent"
fi
echo

# 5. 验证
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

echo
if [[ ${errors} -eq 0 ]]; then
  green "Setup complete! All components installed."
  echo
  echo "Next steps:"
  echo "  1. Open a new Claude Code session to verify rules are active"
  echo "  2. Run: /vibeguard to test the skill"
  echo "  3. Run: /auto-optimize to start project optimization"
  echo "  4. Run: bash ${REPO_DIR}/scripts/compliance_check.sh /path/to/project"
else
  red "Setup completed with ${errors} errors."
  exit 1
fi

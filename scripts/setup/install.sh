#!/usr/bin/env bash
set -euo pipefail

# VibeGuard Setup Script
# 一键部署防幻觉规范到 ~/.claude/ 和 ~/.codex/
#
# 使用方法：
#   bash install.sh                         # 安装（默认 core）
#   bash install.sh --profile full          # 安装 full（含 Stop Gate/Build Check）
#   bash install.sh --check  # 仅检查状态
#   bash install.sh --clean  # 清理安装

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# --- Mode dispatch ---
case "${1:-}" in
  --check) exec bash "${SCRIPT_DIR}/check.sh" ;;
  --clean) exec bash "${SCRIPT_DIR}/clean.sh" ;;
esac

# --- Profile parsing ---
PROFILE="${VIBEGUARD_SETUP_PROFILE:-core}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      [[ $# -lt 2 ]] && { red "ERROR: --profile requires a value (core|full)"; exit 1; }
      PROFILE="$2"; shift 2 ;;
    --profile=*)
      PROFILE="${1#*=}"; shift ;;
    *)
      red "ERROR: unknown argument: $1"
      red "Usage: bash install.sh [--profile core|full] | --check | --clean"
      exit 1 ;;
  esac
done

case "${PROFILE}" in
  core|full) ;;
  *) red "ERROR: unsupported profile: ${PROFILE} (expected core|full)"; exit 1 ;;
esac

echo "=============================="
echo "VibeGuard Setup"
echo "Repository: ${REPO_DIR}"
echo "Profile: ${PROFILE}"
echo "=============================="
echo

# 1. 确保目录存在
echo "Step 1: Prepare directories"
if ! command -v python3 &>/dev/null; then
  red "  ERROR: python3 not found. VibeGuard hooks require Python 3."
  exit 1
fi
mkdir -p "${CLAUDE_DIR}"
green "  ~/.claude/ ready"
# 写入 repo 路径 + 安装 hook wrapper（全平台兼容，无 symlink 依赖）
VIBEGUARD_HOME="${HOME}/.vibeguard"
mkdir -p "${VIBEGUARD_HOME}"
printf '%s' "${REPO_DIR}" > "${VIBEGUARD_HOME}/repo-path"
cp "${REPO_DIR}/hooks/run-hook.sh" "${VIBEGUARD_HOME}/run-hook.sh"
chmod +x "${VIBEGUARD_HOME}/run-hook.sh"
green "  ~/.vibeguard/repo-path + run-hook.sh ready"
echo

# 2. Symlink skills 到 Claude Code
echo "Step 2: Install Claude Code skills"
mkdir -p "${CLAUDE_DIR}/skills"
safe_symlink "${REPO_DIR}/skills/vibeguard" "${CLAUDE_DIR}/skills/vibeguard"
green "  vibeguard -> ~/.claude/skills/vibeguard"
safe_symlink "${REPO_DIR}/workflows/auto-optimize" "${CLAUDE_DIR}/skills/auto-optimize"
green "  auto-optimize -> ~/.claude/skills/auto-optimize"
for skill in strategic-compact eval-harness iterative-retrieval; do
  if [[ -d "${REPO_DIR}/skills/${skill}" ]]; then
    safe_symlink "${REPO_DIR}/skills/${skill}" "${CLAUDE_DIR}/skills/${skill}"
    green "  ${skill} -> ~/.claude/skills/${skill}"
  else
    yellow "  SKIP ${skill} (source not found)"
  fi
done
echo

# 3. Install agents
echo "Step 3: Install agents"
mkdir -p "${CLAUDE_DIR}/agents"
for agent in "${REPO_DIR}"/agents/*.md; do
  [[ -f "$agent" ]] || continue
  name=$(basename "$agent")
  rm -f "${CLAUDE_DIR}/agents/${name}"
  cp "$agent" "${CLAUDE_DIR}/agents/${name}"
  green "  ${name} -> ~/.claude/agents/${name}"
done
echo

# 4. Install context profiles
echo "Step 4: Install context profiles"
mkdir -p "${CLAUDE_DIR}/context-profiles"
for profile in "${REPO_DIR}"/context-profiles/*.md; do
  [[ -f "$profile" ]] || continue
  name=$(basename "$profile")
  cp "$profile" "${CLAUDE_DIR}/context-profiles/${name}"
  green "  ${name} -> ~/.claude/context-profiles/${name}"
done
echo

# 5. Install custom commands
echo "Step 5: Install custom commands"
mkdir -p "${CLAUDE_DIR}/commands"
safe_symlink "${REPO_DIR}/.claude/commands/vibeguard" "${CLAUDE_DIR}/commands/vibeguard"
green "  vibeguard commands -> ~/.claude/commands/vibeguard"
echo

# 5.5. Install Claude Code native rules
echo "Step 5.5: Install native rules"
RULES_SRC="${REPO_DIR}/rules/claude-rules"
RULES_DEST="${HOME}/.claude/rules/vibeguard"
if [[ -d "${RULES_SRC}" ]]; then
  mkdir -p "${RULES_DEST}"
  for subdir in common rust golang typescript python; do
    if [[ -d "${RULES_SRC}/${subdir}" ]]; then
      mkdir -p "${RULES_DEST}/${subdir}"
      cp -r "${RULES_SRC}/${subdir}/." "${RULES_DEST}/${subdir}/"
      green "  ${subdir}/ -> ~/.claude/rules/vibeguard/${subdir}/"
    fi
  done
else
  yellow "  SKIP native rules (source not found: ${RULES_SRC})"
fi
echo

# 6. Symlink workflow skills 到 Codex
echo "Step 6: Install Codex skills"
mkdir -p "${CODEX_DIR}/skills"
for skill in plan-flow fixflow optflow plan-mode auto-optimize; do
  if [[ -d "${REPO_DIR}/workflows/${skill}" ]]; then
    safe_symlink "${REPO_DIR}/workflows/${skill}" "${CODEX_DIR}/skills/${skill}"
    green "  ${skill} -> ~/.codex/skills/${skill}"
  else
    yellow "  SKIP ${skill} (source not found)"
  fi
done
safe_symlink "${REPO_DIR}/skills/vibeguard" "${CODEX_DIR}/skills/vibeguard"
green "  vibeguard -> ~/.codex/skills/vibeguard"
echo

# 7. 检测 auto-run-agent 环境变量
echo "Step 7: Check auto-run-agent"
if [[ -n "${AUTO_RUN_AGENT_DIR:-}" ]] && [[ -d "${AUTO_RUN_AGENT_DIR}" ]]; then
  green "  AUTO_RUN_AGENT_DIR=${AUTO_RUN_AGENT_DIR}"
else
  yellow "  AUTO_RUN_AGENT_DIR not set (optional, needed for auto-optimize Phase 4)"
fi
echo

# 8. Build MCP Server
echo "Step 8: Build MCP Server"
if ! command -v node &>/dev/null; then
  yellow "  Node.js not found, skipping MCP Server build"
elif [[ -f "${REPO_DIR}/mcp-server/dist/index.js" ]] && \
     ! find "${REPO_DIR}/mcp-server/src" -type f -name "*.ts" -newer "${REPO_DIR}/mcp-server/dist/index.js" | grep -q . && \
     [[ "${REPO_DIR}/mcp-server/package.json" -ot "${REPO_DIR}/mcp-server/dist/index.js" ]] && \
     [[ "${REPO_DIR}/mcp-server/tsconfig.json" -ot "${REPO_DIR}/mcp-server/dist/index.js" ]]; then
  yellow "  MCP Server already built and up to date, skipping"
else
  if command -v bun &>/dev/null; then
    (cd "${REPO_DIR}/mcp-server" && bun install --frozen-lockfile 2>/dev/null || bun install && bun run build) 2>&1
  elif [[ -f "${REPO_DIR}/mcp-server/package-lock.json" ]]; then
    (cd "${REPO_DIR}/mcp-server" && npm ci --silent && npm run build --silent) 2>&1
  else
    (cd "${REPO_DIR}/mcp-server" && npm install --silent && npm run build --silent) 2>&1
  fi
  green "  MCP Server built successfully"
fi
echo

# 9. Configure MCP Server + Hooks in settings.json
echo "Step 9: Configure MCP Server + Hooks (${PROFILE} profile)"
if settings_upsert "${SETTINGS_FILE}" "${PROFILE}" >/dev/null 2>&1; then
  green "  MCP Server + Hooks configured in ~/.claude/settings.json (${PROFILE})"
else
  red "  Failed to configure settings.json"
fi
echo

# 9.5. Install scheduled GC (launchd on macOS, systemd on Linux)
echo "Step 9.5: Install scheduled GC"
chmod +x "${REPO_DIR}/scripts/gc-scheduled.sh"
if [[ "$(uname)" == "Darwin" ]]; then
  PLIST_SRC="${SCRIPT_DIR}/com.vibeguard.gc.plist"
  PLIST_DEST="${HOME}/Library/LaunchAgents/com.vibeguard.gc.plist"
  if [[ -f "${PLIST_SRC}" ]]; then
    mkdir -p "${HOME}/Library/LaunchAgents"
    # 先卸载旧的（忽略错误）
    launchctl bootout "gui/$(id -u)/com.vibeguard.gc" 2>/dev/null || true
    # 替换占位符并安装
    sed -e "s|__VIBEGUARD_DIR__|${REPO_DIR}|g" -e "s|__HOME__|${HOME}|g" \
      "${PLIST_SRC}" > "${PLIST_DEST}"
    launchctl bootstrap "gui/$(id -u)" "${PLIST_DEST}" 2>/dev/null \
      && green "  Scheduled GC installed via launchd (every Sunday 3:00 AM)" \
      || yellow "  Scheduled GC plist installed but bootstrap failed (try: launchctl load ${PLIST_DEST})"
  else
    yellow "  SKIP scheduled GC (plist not found)"
  fi
elif [[ "$(uname)" == "Linux" ]] && command -v systemctl &>/dev/null; then
  bash "${REPO_DIR}/scripts/install-systemd.sh" \
    && green "  Scheduled GC installed via systemd (every Sunday 3:00 AM)" \
    || yellow "  Scheduled GC systemd install failed (run: bash scripts/install-systemd.sh)"
else
  yellow "  SKIP scheduled GC (unsupported OS or systemd not found)"
fi
echo

# 9.7. Install pre-commit hook wrapper
echo "Step 9.7: Install pre-commit hook"
PRE_COMMIT_WRAPPER="${VIBEGUARD_HOME}/pre-commit"
cat > "${PRE_COMMIT_WRAPPER}" <<'WRAPPER'
#!/usr/bin/env bash
# VibeGuard Pre-Commit Hook Wrapper — auto-installed by install.sh
set -euo pipefail
VIBEGUARD_DIR="$(cat "$HOME/.vibeguard/repo-path" 2>/dev/null)" || true
if [[ -n "$VIBEGUARD_DIR" ]] && [[ -f "$VIBEGUARD_DIR/hooks/pre-commit-guard.sh" ]]; then
  export VIBEGUARD_DIR
  exec bash "$VIBEGUARD_DIR/hooks/pre-commit-guard.sh"
fi
WRAPPER
chmod +x "${PRE_COMMIT_WRAPPER}"
green "  ~/.vibeguard/pre-commit wrapper ready"
# 自动安装到 VibeGuard 自身仓库
VG_GIT_HOOKS="${REPO_DIR}/.git/hooks"
if [[ -d "${VG_GIT_HOOKS}" ]]; then
  ln -sf "${PRE_COMMIT_WRAPPER}" "${VG_GIT_HOOKS}/pre-commit"
  green "  pre-commit hook installed to vibeguard repo"
fi
echo

# 10. Re-inject CLAUDE.md
echo "Step 10: Update VibeGuard rules in CLAUDE.md"
RULES_FILE="${REPO_DIR}/claude-md/vibeguard-rules.md"
if result=$(python3 "${CLAUDE_MD_HELPER}" inject "${CLAUDE_DIR}/CLAUDE.md" "${RULES_FILE}" "${REPO_DIR}" 2>&1); then
  green "  VibeGuard rules synced to ~/.claude/CLAUDE.md (${result})"
else
  red "  Failed to update CLAUDE.md"
fi
echo

# 11. 验证
echo "Step 11: Verification"
echo "=============================="
bash "${SCRIPT_DIR}/check.sh"
echo
green "Setup complete! All components installed."
echo
echo "Next steps:"
echo "  1. Open a new Claude Code session to verify rules are active"
echo "  2. Switch profile: bash install.sh --profile full|core"
echo "  3. Run: /vibeguard:preflight <project_dir>"
echo "  4. Run: /vibeguard:check <project_dir>"
echo
echo "Git Pre-Commit Guard:"
echo "  已自动安装到 VibeGuard 仓库"
echo "  其他项目：bash scripts/project-init.sh <project_dir>"

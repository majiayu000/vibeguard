#!/usr/bin/env bash
set -euo pipefail

# VibeGuard Setup Script
# 一键部署防幻觉规范到 ~/.claude/ 和 ~/.codex/
#
# 使用方法：
#   bash install.sh                                    # 安装（默认 core）
#   bash install.sh --profile full                     # 安装 full（含 Stop Gate/Build Check）
#   bash install.sh --profile minimal                  # 最小安装（仅 pre-hooks）
#   bash install.sh --profile strict                   # 严格模式（与 full 相同的 hook 集合）
#   bash install.sh --languages rust,python            # 只安装指定语言的规则和守卫
#   bash install.sh --profile full --languages rust    # 组合使用
#   bash install.sh --check                            # 仅检查状态
#   bash install.sh --clean                            # 清理安装

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
source "${SCRIPT_DIR}/../lib/install-state.sh"
source "${SCRIPT_DIR}/targets/claude-home.sh"
source "${SCRIPT_DIR}/targets/codex-home.sh"

# --- Mode dispatch ---
case "${1:-}" in
  --check) exec bash "${SCRIPT_DIR}/check.sh" ;;
  --clean) exec bash "${SCRIPT_DIR}/clean.sh" ;;
esac

# --- Argument parsing ---
PROFILE="${VIBEGUARD_SETUP_PROFILE:-core}"
LANGUAGES=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      [[ $# -lt 2 ]] && { red "ERROR: --profile requires a value (minimal|core|full|strict)"; exit 1; }
      PROFILE="$2"; shift 2 ;;
    --profile=*)
      PROFILE="${1#*=}"; shift ;;
    --languages)
      [[ $# -lt 2 ]] && { red "ERROR: --languages requires a value (e.g. rust,python,go,typescript)"; exit 1; }
      LANGUAGES="$2"; shift 2 ;;
    --languages=*)
      LANGUAGES="${1#*=}"; shift ;;
    *)
      red "ERROR: unknown argument: $1"
      red "Usage: bash install.sh [--profile minimal|core|full|strict] [--languages lang1,lang2] | --check | --clean"
      exit 1 ;;
  esac
done

case "${PROFILE}" in
  minimal|core|full|strict) ;;
  *) red "ERROR: unsupported profile: ${PROFILE} (expected minimal|core|full|strict)"; exit 1 ;;
esac

# Parse languages into array
declare -a LANG_FILTER=()
if [[ -n "$LANGUAGES" ]]; then
  IFS=',' read -ra LANG_FILTER <<< "$LANGUAGES"
fi

# Check if a language is in the filter (empty filter = install all)
lang_selected() {
  local lang="$1"
  if [[ ${#LANG_FILTER[@]} -eq 0 ]]; then
    return 0  # no filter = all selected
  fi
  for l in "${LANG_FILTER[@]}"; do
    l="${l// /}"  # trim spaces
    # normalize: golang -> go in filter
    [[ "$l" == "golang" ]] && l="go"
    [[ "$lang" == "golang" ]] && lang="go"
    if [[ "$l" == "$lang" ]]; then
      return 0
    fi
  done
  return 1
}

echo "=============================="
echo "VibeGuard Setup"
echo "Repository: ${REPO_DIR}"
echo "Profile: ${PROFILE}"
if [[ -n "$LANGUAGES" ]]; then
  echo "Languages: ${LANGUAGES}"
fi
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
cp "${REPO_DIR}/hooks/run-hook-codex.sh" "${VIBEGUARD_HOME}/run-hook-codex.sh"
chmod +x "${VIBEGUARD_HOME}/run-hook.sh" "${VIBEGUARD_HOME}/run-hook-codex.sh"
green "  ~/.vibeguard/repo-path + run-hook.sh + run-hook-codex.sh ready"

# Create user-rules directory for custom rules
mkdir -p "${VIBEGUARD_HOME}/user-rules"
green "  ~/.vibeguard/user-rules/ ready (add custom .md rules here)"

# Install hooks and guards snapshot (isolated from dev repo — prevents dirty state from breaking hooks)
INSTALLED_DIR="${VIBEGUARD_HOME}/installed"
mkdir -p "${INSTALLED_DIR}/hooks" "${INSTALLED_DIR}/guards"
rm -rf "${INSTALLED_DIR}/hooks" "${INSTALLED_DIR}/guards"
cp -r "${REPO_DIR}/hooks" "${INSTALLED_DIR}/"
cp -r "${REPO_DIR}/guards" "${INSTALLED_DIR}/"
printf '%s' "$(git -C "${REPO_DIR}" rev-parse --short HEAD 2>/dev/null || echo 'unknown')" > "${INSTALLED_DIR}/version"
green "  ~/.vibeguard/installed/ hooks+guards snapshot ($(cat "${INSTALLED_DIR}/version"))"

# Initialize install state tracking
state_init "$PROFILE" "$LANGUAGES"
state_record_file "${VIBEGUARD_HOME}/repo-path" "generated/repo-path" "copy"
state_record_file "${VIBEGUARD_HOME}/run-hook.sh" "hooks/run-hook.sh" "copy"
green "  Install state tracker initialized"
echo

install_claude_home_assets

install_codex_home_assets

# 7. 检测 auto-run-agent 环境变量
echo "Step 7: Check auto-run-agent"
if [[ -n "${AUTO_RUN_AGENT_DIR:-}" ]] && [[ -d "${AUTO_RUN_AGENT_DIR}" ]]; then
  green "  AUTO_RUN_AGENT_DIR=${AUTO_RUN_AGENT_DIR}"
else
  yellow "  AUTO_RUN_AGENT_DIR not set (optional, needed for auto-optimize Phase 4)"
fi
echo


configure_claude_home_runtime

# 9.2. Remove legacy Codex MCP config from previous installs
configure_codex_home_runtime

# 9.5. Install scheduled GC (launchd on macOS, systemd on Linux)
echo "Step 9.5: Install scheduled GC"
chmod +x "${REPO_DIR}/scripts/gc/gc-scheduled.sh"
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
state_record_file "${PRE_COMMIT_WRAPPER}" "generated/pre-commit-wrapper" "copy"
green "  ~/.vibeguard/pre-commit wrapper ready"
# 自动安装到 VibeGuard 自身仓库
VG_GIT_HOOKS="${REPO_DIR}/.git/hooks"
if [[ -d "${VG_GIT_HOOKS}" ]]; then
  ln -sf "${PRE_COMMIT_WRAPPER}" "${VG_GIT_HOOKS}/pre-commit"
  green "  pre-commit hook installed to vibeguard repo"
fi
echo

inject_claude_home_rules

# 11. 验证
echo "Step 11: Verification"
echo "=============================="
bash "${SCRIPT_DIR}/check.sh"
echo
green "Setup complete! All components installed."
echo
echo "Next steps:"
echo "  1. Open a new Claude Code session to verify rules are active"
echo "  2. Switch profile: bash install.sh --profile minimal|core|full|strict"
echo "  3. Run: /vibeguard:preflight <project_dir>"
echo "  4. Run: /vibeguard:check <project_dir>"
echo
echo "Runtime configuration (env vars or .vibeguard.json):"
echo "  VIBEGUARD_PROFILE=minimal|standard|strict    Runtime profile"
echo "  VIBEGUARD_ENFORCEMENT=block|warn|off          Enforcement level"
echo "  VIBEGUARD_DISABLED_HOOKS=hook1,hook2           Disable specific hooks"
echo
echo "Git Pre-Commit Guard:"
echo "  已自动安装到 VibeGuard 仓库"
echo "  其他项目：bash scripts/project-init.sh <project_dir>"

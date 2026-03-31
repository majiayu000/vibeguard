#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
source "${SCRIPT_DIR}/../lib/install-state.sh"
source "${SCRIPT_DIR}/targets/claude-home.sh"
source "${SCRIPT_DIR}/targets/codex-home.sh"

echo "VibeGuard Installation Status"
echo "=============================="

# Check hook wrapper
VIBEGUARD_HOME="${HOME}/.vibeguard"
if [[ -f "${VIBEGUARD_HOME}/repo-path" ]] && [[ -f "${VIBEGUARD_HOME}/run-hook.sh" ]]; then
  _repo=$(<"${VIBEGUARD_HOME}/repo-path")
  if [[ -d "$_repo/hooks" ]]; then
    green "[OK] Hook wrapper ready (repo: ${_repo})"
  else
    red "[BROKEN] repo-path points to missing directory: ${_repo}"
  fi
else
  yellow "[MISSING] Hook wrapper not installed (~/.vibeguard/run-hook.sh)"
fi

check_claude_home_installation

# Check scheduled GC
if [[ "$(uname)" == "Darwin" ]]; then
  if launchctl print "gui/$(id -u)/com.vibeguard.gc" &>/dev/null; then
    green "[OK] Scheduled GC active via launchd (com.vibeguard.gc)"
  elif [[ -f "${HOME}/Library/LaunchAgents/com.vibeguard.gc.plist" ]]; then
    yellow "[WARN] Scheduled GC plist exists but not loaded"
  else
    yellow "[INFO] Scheduled GC not installed (optional)"
  fi
elif [[ "$(uname)" == "Linux" ]] && command -v systemctl &>/dev/null; then
  if systemctl --user is-active vibeguard-gc.timer &>/dev/null; then
    green "[OK] Scheduled GC active via systemd (vibeguard-gc.timer)"
  elif [[ -f "${HOME}/.config/systemd/user/vibeguard-gc.timer" ]]; then
    yellow "[WARN] Scheduled GC unit exists but timer not active"
  else
    yellow "[INFO] Scheduled GC not installed (optional, run: bash scripts/install-systemd.sh)"
  fi
fi

check_codex_home_installation

# Check AUTO_RUN_AGENT_DIR
if [[ -n "${AUTO_RUN_AGENT_DIR:-}" ]] && [[ -d "${AUTO_RUN_AGENT_DIR}" ]]; then
  green "[OK] AUTO_RUN_AGENT_DIR=${AUTO_RUN_AGENT_DIR}"
else
  yellow "[INFO] AUTO_RUN_AGENT_DIR not set (auto-optimize Phase 4 requires it)"
fi

# Check ast-grep (required by TS and Rust AST-level guards)
if command -v ast-grep >/dev/null 2>&1; then
  green "[OK] ast-grep: $(ast-grep --version 2>/dev/null | head -1)"
else
  yellow "[MISSING] ast-grep not installed — TS/Rust AST guards will SKIP (install: brew install ast-grep)"
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

# Check Codex CLI (optional)
if command -v codex &>/dev/null; then
  green "[OK] Codex CLI available (enables /vibeguard:cross-review)"
else
  yellow "[INFO] Codex CLI not found (install: npm i -g @openai/codex for /vibeguard:cross-review)"
fi

# Check install state (drift detection)
echo
echo "Install State"
echo "------------------------------"
drift_output=$(state_check_drift 2>/dev/null)
if [[ "$drift_output" == "NO_STATE" ]]; then
  yellow "[INFO] No install state found (re-run setup.sh to enable state tracking)"
elif echo "$drift_output" | grep -q "STATUS: CLEAN"; then
  tracked=$(echo "$drift_output" | grep "Total tracked" | head -1)
  green "[OK] ${tracked}"
else
  echo "$drift_output" | grep -E "^(MISSING|DRIFT):" | while read -r line; do
    red "  ${line}"
  done
  yellow "[WARN] Run 'bash setup.sh' to repair drifted files"
fi

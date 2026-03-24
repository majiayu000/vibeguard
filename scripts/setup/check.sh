#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
source "${SCRIPT_DIR}/../lib/install-state.sh"

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

# Check CLAUDE.md
if [[ -f "${CLAUDE_DIR}/CLAUDE.md" ]] && grep -q "VibeGuard" "${CLAUDE_DIR}/CLAUDE.md" 2>/dev/null; then
  green "[OK] VibeGuard rules in ~/.claude/CLAUDE.md"
else
  red "[MISSING] VibeGuard rules not in ~/.claude/CLAUDE.md"
fi

# Check Claude Code skills (symlink exists AND target is valid)
for skill in vibeguard auto-optimize strategic-compact eval-harness iterative-retrieval; do
  link="${CLAUDE_DIR}/skills/${skill}"
  if [[ -L "${link}" ]]; then
    if [[ -e "${link}" ]]; then
      green "[OK] ${skill} skill symlinked to ~/.claude/skills/"
    else
      red "[BROKEN] ${skill} symlink exists but target missing: $(readlink "${link}")"
    fi
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

# Check native rules
RULES_DEST="${HOME}/.claude/rules/vibeguard"
if [[ -d "${RULES_DEST}" ]]; then
  rule_file_count=$(find "${RULES_DEST}" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${rule_file_count}" -ge 7 ]]; then
    green "[OK] ${rule_file_count} native rule files in ~/.claude/rules/vibeguard/"
  else
    yellow "[PARTIAL] Only ${rule_file_count} native rule files (expected 7+)"
  fi

  # Validate rule count in CLAUDE.md matches actual count.
  # Use find to avoid failing when some language directories are intentionally absent
  # (for example, setup.sh --languages rust).
  actual_rule_count=0
  while IFS= read -r rule_file; do
    file_count=$(grep -cE '^## [A-Z]+-[0-9]+' "${rule_file}" 2>/dev/null || true)
    actual_rule_count=$((actual_rule_count + file_count))
  done < <(find "${RULES_DEST}" -type f -name "*.md" 2>/dev/null)
  claude_md="${CLAUDE_DIR}/CLAUDE.md"
  if [[ -f "${claude_md}" ]]; then
    declared_count=$(grep -o '[0-9]* 条规则' "${claude_md}" 2>/dev/null | grep -o '[0-9]*' | head -1)
    declared_count="${declared_count:-0}"
    if [[ "${actual_rule_count}" -eq "${declared_count}" ]]; then
      green "[OK] Rule count in sync: ${actual_rule_count} rules"
    else
      yellow "[DRIFT] CLAUDE.md declares ${declared_count} rules, actual: ${actual_rule_count}"
      # Auto-fix: update the count in CLAUDE.md
      if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s/${declared_count} 条规则/${actual_rule_count} 条规则/" "${claude_md}"
      else
        sed -i "s/${declared_count} 条规则/${actual_rule_count} 条规则/" "${claude_md}"
      fi
      green "[FIXED] Updated CLAUDE.md rule count to ${actual_rule_count}"
    fi
  fi
else
  red "[MISSING] Native rules not in ~/.claude/rules/vibeguard/"
fi

# Check Codex skills (symlink exists AND target is valid)
for skill in plan-flow fixflow optflow plan-mode vibeguard auto-optimize; do
  link="${CODEX_DIR}/skills/${skill}"
  if [[ -L "${link}" ]]; then
    if [[ -e "${link}" ]]; then
      green "[OK] ${skill} skill symlinked to ~/.codex/skills/"
    else
      red "[BROKEN] ${skill} symlink exists but target missing: $(readlink "${link}")"
    fi
  else
    yellow "[MISSING] ${skill} skill not in ~/.codex/skills/"
  fi
done

# Check Codex MCP config (separate from Claude settings.json)
if codex_mcp_check; then
  green "[OK] Codex MCP configured in ~/.codex/config.toml"
else
  yellow "[MISSING] Codex MCP not configured in ~/.codex/config.toml"
fi

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
  green "[OK] PostToolUse hooks configured (guard_check + Edit quality + Write dedup)"
else
  yellow "[MISSING] PostToolUse hooks not fully configured"
fi

if settings_check "${SETTINGS_FILE}" "full-hooks"; then
  green "[OK] Full profile hooks configured (Stop gate + Build check + Learn evaluator)"
else
  yellow "[INFO] Full profile hooks not configured (current install may be core profile)"
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

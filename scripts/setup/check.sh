#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

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
    green "[OK] Scheduled GC active (com.vibeguard.gc)"
  elif [[ -f "${HOME}/Library/LaunchAgents/com.vibeguard.gc.plist" ]]; then
    yellow "[WARN] Scheduled GC plist exists but not loaded"
  else
    yellow "[INFO] Scheduled GC not installed (optional)"
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

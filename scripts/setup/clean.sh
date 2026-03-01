#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

echo "Cleaning VibeGuard installation..."

# Remove CLAUDE.md VibeGuard section
if [[ -f "${CLAUDE_DIR}/CLAUDE.md" ]]; then
  result=$(python3 "${CLAUDE_MD_HELPER}" remove "${CLAUDE_DIR}/CLAUDE.md" 2>/dev/null || echo "ERROR")
  case "$result" in
    REMOVED|REMOVED_LEGACY) yellow "Removed VibeGuard rules from ~/.claude/CLAUDE.md" ;;
    NOT_FOUND) yellow "No VibeGuard rules found in ~/.claude/CLAUDE.md" ;;
    *) red "Failed to clean CLAUDE.md" ;;
  esac
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
if [[ -f "${SETTINGS_FILE}" ]]; then
  if clean_result=$(settings_remove "${SETTINGS_FILE}" 2>/dev/null); then
    if [[ "${clean_result}" == "CHANGED" ]]; then
      yellow "Removed MCP Server and Hooks from settings.json"
    fi
  fi
fi

green "VibeGuard cleaned."

#!/usr/bin/env bash

install_codex_home_assets() {
  echo "Step 6: Install Codex skills"
  mkdir -p "${CODEX_DIR}/skills"
  for skill in plan-flow fixflow optflow plan-mode auto-optimize; do
    if [[ -d "${REPO_DIR}/workflows/${skill}" ]]; then
      safe_symlink "${REPO_DIR}/workflows/${skill}" "${CODEX_DIR}/skills/${skill}"
      state_record_file "${CODEX_DIR}/skills/${skill}" "workflows/${skill}" "symlink"
      green "  ${skill} -> ~/.codex/skills/${skill}"
    else
      yellow "  SKIP ${skill} (source not found)"
    fi
  done
  safe_symlink "${REPO_DIR}/skills/vibeguard" "${CODEX_DIR}/skills/vibeguard"
  state_record_file "${CODEX_DIR}/skills/vibeguard" "skills/vibeguard" "symlink"
  green "  vibeguard -> ~/.codex/skills/vibeguard"
  echo
}

configure_codex_home_runtime() {
  echo "Step 9.2: Configure Codex MCP Server"
  local codex_output codex_strategy
  if codex_output=$(codex_mcp_upsert 2>&1); then
    if [[ -f "${CODEX_DIR}/config.toml" ]]; then
      state_record_file "${CODEX_DIR}/config.toml" "generated/codex-config.toml" "copy"
    fi
    codex_strategy=$(echo "${codex_output}" | awk -F: '/^STRATEGY:/{print $2}' | head -1)
    codex_strategy="${codex_strategy:-unknown}"
    if echo "${codex_output}" | grep -q "CHANGED"; then
      green "  Codex MCP configured in ~/.codex/config.toml (${codex_strategy})"
    else
      green "  Codex MCP already up to date (${codex_strategy})"
    fi
  else
    yellow "  SKIP Codex MCP config (reason: ${codex_output})"
  fi
  echo
}

check_codex_home_installation() {
  local link
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

  if codex_mcp_check; then
    green "[OK] Codex MCP configured in ~/.codex/config.toml"
  else
    yellow "[MISSING] Codex MCP not configured in ~/.codex/config.toml"
  fi
}

clean_codex_home_installation() {
  local skill
  for skill in plan-flow fixflow optflow plan-mode vibeguard auto-optimize; do
    rm -f "${CODEX_DIR}/skills/${skill}"
  done

  local codex_clean_result
  if codex_clean_result=$(codex_mcp_remove 2>/dev/null); then
    if [[ "${codex_clean_result}" == *"CHANGED"* ]]; then
      yellow "Removed VibeGuard MCP from ~/.codex/config.toml"
    fi
  fi
}

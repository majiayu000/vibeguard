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

  echo "Step 6.5: Install Codex hooks"
  # Copy Codex-specific hook wrapper
  cp "${REPO_DIR}/hooks/run-hook-codex.sh" "${HOME}/.vibeguard/run-hook-codex.sh"
  chmod +x "${HOME}/.vibeguard/run-hook-codex.sh"
  state_record_file "${HOME}/.vibeguard/run-hook-codex.sh" "hooks/run-hook-codex.sh" "copy"
  green "  ~/.vibeguard/run-hook-codex.sh ready"

  # Merge VibeGuard hooks into ~/.codex/hooks.json (do not overwrite existing hooks)
  local wrapper="${HOME}/.vibeguard/run-hook-codex.sh"
  local hooks_file="${CODEX_DIR}/hooks.json"
  local hooks_result
  hooks_result=$(python3 "${CODEX_HOOKS_HELPER}" upsert-vibeguard --hooks-file "${hooks_file}" --wrapper "${wrapper}" 2>/dev/null || echo "ERROR")
  if [[ "${hooks_result}" == "CHANGED" || "${hooks_result}" == "SKIP" ]]; then
    state_record_file "${hooks_file}" "generated/codex-hooks.json" "copy"
    green "  ~/.codex/hooks.json merged (VibeGuard hooks upserted)"
    yellow "  Codex capability profile: Bash approvals + Stop hooks are native; Edit/Write hooks stay unsupported here"
  else
    red "  Failed to update ~/.codex/hooks.json"
  fi

  # Enable codex_hooks feature flag in config.toml
  _enable_codex_hooks_feature
  echo
}

_enable_codex_hooks_feature() {
  local config="${CODEX_DIR}/config.toml"
  local result
  if ! result=$(python3 "${CODEX_CONFIG_HELPER}" enable-codex-hooks --config-file "${config}" 2>/dev/null); then
    red "  Failed to enable codex_hooks feature in config.toml"
    return 1
  fi
  case "${result}" in
    CHANGED)
      green "  codex_hooks feature enabled in config.toml"
      ;;
    SKIP)
      green "  codex_hooks feature already enabled"
      ;;
    *)
      red "  Failed to enable codex_hooks feature in config.toml"
      return 1
      ;;
  esac
}

_remove_legacy_codex_mcp_config() {
  local config="${CODEX_DIR}/config.toml"
  python3 "${CODEX_CONFIG_HELPER}" remove-legacy-vibeguard-mcp --config-file "${config}"
}

_has_legacy_codex_mcp_config() {
  local config="${CODEX_DIR}/config.toml"
  [[ -f "${config}" ]] && grep -q '^\[mcp_servers\.vibeguard\]' "${config}" 2>/dev/null
}

configure_codex_home_runtime() {
  echo "Step 9.2: Remove legacy Codex MCP config"
  local cleanup_result
  if ! cleanup_result="$(_remove_legacy_codex_mcp_config 2>/dev/null)"; then
    red "  Failed to remove legacy Codex MCP config from ~/.codex/config.toml"
    return 1
  fi
  if [[ -f "${CODEX_DIR}/config.toml" ]]; then
    state_record_file "${CODEX_DIR}/config.toml" "generated/codex-config.toml" "copy"
  fi
  if [[ "${cleanup_result}" == "CHANGED" ]]; then
    green "  Removed legacy VibeGuard MCP block from ~/.codex/config.toml"
  else
    green "  No legacy Codex MCP config found"
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

  # Check hooks
  if [[ -f "${CODEX_DIR}/hooks.json" ]]; then
    local wrapper="${HOME}/.vibeguard/run-hook-codex.sh"
    local hook_count
    hook_count=$(python3 -c "
import json
with open('${CODEX_DIR}/hooks.json') as f:
    data = json.load(f)
total = sum(len(entries) for entries in data.get('hooks', {}).values() if isinstance(entries, list))
print(total)
" 2>/dev/null || echo "?")
    green "[OK] Codex hooks.json present (${hook_count} total entries)"

    if python3 "${CODEX_HOOKS_HELPER}" check-vibeguard --hooks-file "${CODEX_DIR}/hooks.json" --wrapper "${wrapper}" >/dev/null 2>&1; then
      green "[OK] VibeGuard hooks merged in ~/.codex/hooks.json"
    else
      yellow "[MISSING] VibeGuard hooks not fully configured in ~/.codex/hooks.json"
    fi
  else
    yellow "[MISSING] Codex hooks.json not installed"
  fi

  if [[ -f "${HOME}/.vibeguard/run-hook-codex.sh" ]]; then
    green "[OK] Codex hook wrapper (~/.vibeguard/run-hook-codex.sh)"
  else
    yellow "[MISSING] Codex hook wrapper not installed"
  fi

  yellow "[INFO] Codex runtime scope: Bash approvals + Stop hooks only; Edit/Write/analysis-paralysis require Claude Code or the app-server wrapper"

  # Check feature flag
  if [[ -f "${CODEX_DIR}/config.toml" ]] && grep -Eq '^codex_hooks[[:space:]]*=[[:space:]]*true$' "${CODEX_DIR}/config.toml" 2>/dev/null; then
    green "[OK] codex_hooks feature enabled in config.toml"
  else
    yellow "[MISSING] codex_hooks feature not enabled in ~/.codex/config.toml"
  fi

  if _has_legacy_codex_mcp_config; then
    yellow "[LEGACY] Legacy VibeGuard MCP block still present in ~/.codex/config.toml"
  else
    green "[OK] No legacy VibeGuard MCP block in ~/.codex/config.toml"
  fi
}

clean_codex_home_installation() {
  local skill
  for skill in plan-flow fixflow optflow plan-mode vibeguard auto-optimize; do
    rm -f "${CODEX_DIR}/skills/${skill}"
  done

  # Remove only VibeGuard-managed entries from hooks.json (do not delete third-party hooks)
  local hooks_cleanup_result
  hooks_cleanup_result=$(python3 "${CODEX_HOOKS_HELPER}" remove-vibeguard --hooks-file "${CODEX_DIR}/hooks.json" 2>/dev/null || echo "ERROR")
  case "${hooks_cleanup_result}" in
    CHANGED)
      yellow "Removed VibeGuard hook entries from ~/.codex/hooks.json"
      ;;
    SKIP)
      yellow "No VibeGuard hook entries found in ~/.codex/hooks.json"
      ;;
    *)
      red "Failed to clean VibeGuard entries in ~/.codex/hooks.json"
      ;;
  esac

  rm -f "${HOME}/.vibeguard/run-hook-codex.sh"
  yellow "Removed Codex hook wrapper"

  # Keep codex_hooks flag untouched to avoid affecting other toolchains.

  local cleanup_result
  if ! cleanup_result="$(_remove_legacy_codex_mcp_config 2>/dev/null)"; then
    red "Failed to remove legacy Codex MCP config from ~/.codex/config.toml"
    return 1
  fi
  if [[ "${cleanup_result}" == "CHANGED" ]]; then
    yellow "Removed legacy VibeGuard MCP block from ~/.codex/config.toml"
  fi
}

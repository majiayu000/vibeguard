#!/usr/bin/env bash

install_claude_home_assets() {
  echo "Step 2: Install Claude Code skills"
  mkdir -p "${CLAUDE_DIR}/skills"
  safe_symlink "${REPO_DIR}/skills/vibeguard" "${CLAUDE_DIR}/skills/vibeguard"
  state_record_file "${CLAUDE_DIR}/skills/vibeguard" "skills/vibeguard" "symlink"
  green "  vibeguard -> ~/.claude/skills/vibeguard"
  safe_symlink "${REPO_DIR}/workflows/auto-optimize" "${CLAUDE_DIR}/skills/auto-optimize"
  state_record_file "${CLAUDE_DIR}/skills/auto-optimize" "workflows/auto-optimize" "symlink"
  green "  auto-optimize -> ~/.claude/skills/auto-optimize"
  for skill in strategic-compact eval-harness iterative-retrieval; do
    if [[ -d "${REPO_DIR}/skills/${skill}" ]]; then
      safe_symlink "${REPO_DIR}/skills/${skill}" "${CLAUDE_DIR}/skills/${skill}"
      state_record_file "${CLAUDE_DIR}/skills/${skill}" "skills/${skill}" "symlink"
      green "  ${skill} -> ~/.claude/skills/${skill}"
    else
      yellow "  SKIP ${skill} (source not found)"
    fi
  done
  echo

  echo "Step 3: Install agents"
  mkdir -p "${CLAUDE_DIR}/agents"
  for agent in "${REPO_DIR}"/agents/*.md; do
    [[ -f "$agent" ]] || continue
    local name
    name=$(basename "$agent")
    rm -f "${CLAUDE_DIR}/agents/${name}"
    cp "$agent" "${CLAUDE_DIR}/agents/${name}"
    state_record_file "${CLAUDE_DIR}/agents/${name}" "agents/${name}" "copy"
    green "  ${name} -> ~/.claude/agents/${name}"
  done
  echo

  echo "Step 4: Install context profiles"
  mkdir -p "${CLAUDE_DIR}/context-profiles"
  for profile in "${REPO_DIR}"/context-profiles/*.md; do
    [[ -f "$profile" ]] || continue
    local name
    name=$(basename "$profile")
    cp "$profile" "${CLAUDE_DIR}/context-profiles/${name}"
    state_record_file "${CLAUDE_DIR}/context-profiles/${name}" "context-profiles/${name}" "copy"
    green "  ${name} -> ~/.claude/context-profiles/${name}"
  done
  echo

  echo "Step 5: Install custom commands"
  mkdir -p "${CLAUDE_DIR}/commands"
  safe_symlink "${REPO_DIR}/.claude/commands/vibeguard" "${CLAUDE_DIR}/commands/vibeguard"
  state_record_file "${CLAUDE_DIR}/commands/vibeguard" ".claude/commands/vibeguard" "symlink"
  green "  vibeguard commands -> ~/.claude/commands/vibeguard"
  echo

  echo "Step 5.5: Install native rules"
  local rules_src="${REPO_DIR}/rules/claude-rules"
  local rules_dest="${HOME}/.claude/rules/vibeguard"
  if [[ -d "${rules_src}" ]]; then
    mkdir -p "${rules_dest}"
    if [[ -d "${rules_src}/common" ]]; then
      mkdir -p "${rules_dest}/common"
      cp -r "${rules_src}/common/." "${rules_dest}/common/"
      state_record_tree "${rules_dest}/common" "rules/claude-rules/common"
      green "  common/ -> ~/.claude/rules/vibeguard/common/"
    fi
    for subdir in rust golang typescript python; do
      if [[ -d "${rules_src}/${subdir}" ]]; then
        if lang_selected "$subdir"; then
          mkdir -p "${rules_dest}/${subdir}"
          cp -r "${rules_src}/${subdir}/." "${rules_dest}/${subdir}/"
          state_record_tree "${rules_dest}/${subdir}" "rules/claude-rules/${subdir}"
          green "  ${subdir}/ -> ~/.claude/rules/vibeguard/${subdir}/"
        else
          if [[ -d "${rules_dest}/${subdir}" ]]; then
            rm -rf "${rules_dest}/${subdir}"
            yellow "  ${subdir}/ removed (not in --languages filter)"
          else
            yellow "  SKIP ${subdir}/ (not in --languages filter)"
          fi
        fi
      fi
    done
    if [[ -d "${VIBEGUARD_HOME}/user-rules" ]]; then
      local local_rules_count
      local_rules_count=$(find "${VIBEGUARD_HOME}/user-rules" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
      if [[ "${local_rules_count}" -gt 0 ]]; then
        mkdir -p "${rules_dest}/custom"
        cp "${VIBEGUARD_HOME}/user-rules/"*.md "${rules_dest}/custom/" 2>/dev/null || true
        state_record_tree "${rules_dest}/custom" "user-rules"
        green "  custom/ -> ~/.claude/rules/vibeguard/custom/ (${local_rules_count} user rules)"
      fi
    fi
  else
    yellow "  SKIP native rules (source not found: ${rules_src})"
  fi
  echo
}

configure_claude_home_runtime() {
  echo "Step 9: Configure Claude hooks (${PROFILE} profile)"
  local settings_profile="${PROFILE}"
  case "${PROFILE}" in
    minimal) settings_profile="core" ;;
  esac
  if settings_upsert "${SETTINGS_FILE}" "${settings_profile}" >/dev/null 2>&1; then
    state_record_file "${SETTINGS_FILE}" "generated/settings.json" "copy"
    green "  Hooks configured in ~/.claude/settings.json (${PROFILE})"
  else
    red "  Failed to configure settings.json"
  fi
  echo
}

inject_claude_home_rules() {
  echo "Step 10: Update VibeGuard rules in CLAUDE.md"
  local rules_file="${REPO_DIR}/claude-md/vibeguard-rules.md"
  if result=$(python3 "${CLAUDE_MD_HELPER}" inject "${CLAUDE_DIR}/CLAUDE.md" "${rules_file}" "${REPO_DIR}" 2>&1); then
    if [[ -f "${CLAUDE_DIR}/CLAUDE.md" ]]; then
      state_record_file "${CLAUDE_DIR}/CLAUDE.md" "generated/CLAUDE.md" "copy"
    fi
    green "  VibeGuard rules synced to ~/.claude/CLAUDE.md (${result})"
  else
    red "  Failed to update CLAUDE.md"
  fi
  echo
}

check_claude_home_installation() {
  if [[ -f "${CLAUDE_DIR}/CLAUDE.md" ]] && grep -q "VibeGuard" "${CLAUDE_DIR}/CLAUDE.md" 2>/dev/null; then
    green "[OK] VibeGuard rules in ~/.claude/CLAUDE.md"
  else
    red "[MISSING] VibeGuard rules not in ~/.claude/CLAUDE.md"
  fi

  local link
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

  if [[ -L "${CLAUDE_DIR}/commands/vibeguard" ]]; then
    green "[OK] vibeguard commands symlinked to ~/.claude/commands/"
  else
    red "[MISSING] vibeguard commands not in ~/.claude/commands/"
  fi

  local agent_count
  if [[ -d "${CLAUDE_DIR}/agents" ]] && [[ -n "$(ls -A "${CLAUDE_DIR}/agents" 2>/dev/null)" ]]; then
    agent_count=$(ls "${CLAUDE_DIR}/agents"/*.md 2>/dev/null | wc -l | tr -d ' ')
    green "[OK] ${agent_count} agents installed in ~/.claude/agents/"
  else
    yellow "[MISSING] agents not in ~/.claude/agents/"
  fi

  if [[ -d "${CLAUDE_DIR}/context-profiles" ]] && [[ -n "$(ls -A "${CLAUDE_DIR}/context-profiles" 2>/dev/null)" ]]; then
    green "[OK] context profiles installed in ~/.claude/context-profiles/"
  else
    yellow "[MISSING] context profiles not in ~/.claude/context-profiles/"
  fi

  local rules_dest="${HOME}/.claude/rules/vibeguard"
  local rule_file_count actual_rule_count file_count claude_md declared_count
  if [[ -d "${rules_dest}" ]]; then
    rule_file_count=$(find "${rules_dest}" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${rule_file_count}" -ge 7 ]]; then
      green "[OK] ${rule_file_count} native rule files in ~/.claude/rules/vibeguard/"
    else
      yellow "[PARTIAL] Only ${rule_file_count} native rule files (expected 7+)"
    fi

    actual_rule_count=0
    while IFS= read -r rule_file; do
      file_count=$(grep -cE '^## [A-Z]+-[0-9]+' "${rule_file}" 2>/dev/null || true)
      actual_rule_count=$((actual_rule_count + file_count))
    done < <(find "${rules_dest}" -type f -name "*.md" 2>/dev/null)
    claude_md="${CLAUDE_DIR}/CLAUDE.md"
    if [[ -f "${claude_md}" ]]; then
      declared_count=$(grep -o '[0-9]* rules' "${claude_md}" 2>/dev/null | grep -o '[0-9]*' | head -1)
      declared_count="${declared_count:-0}"
      if [[ "${actual_rule_count}" -eq "${declared_count}" ]]; then
        green "[OK] Rule count in sync: ${actual_rule_count} rules"
      else
        yellow "[DRIFT] CLAUDE.md declares ${declared_count} rules, actual: ${actual_rule_count}"
        if [[ "$(uname)" == "Darwin" ]]; then
          sed -i '' "s/${declared_count} rules/${actual_rule_count} rules/" "${claude_md}"
        else
          sed -i "s/${declared_count} rules/${actual_rule_count} rules/" "${claude_md}"
        fi
        green "[FIXED] Updated CLAUDE.md rule count to ${actual_rule_count}"
      fi
    fi
  else
    red "[MISSING] Native rules not in ~/.claude/rules/vibeguard/"
  fi

  if settings_check "${SETTINGS_FILE}" "pre-hooks"; then
    green "[OK] PreToolUse hooks configured (Write block + Bash block + Edit guard)"
  else
    yellow "[MISSING] PreToolUse hooks not fully configured"
  fi

  if settings_check "${SETTINGS_FILE}" "post-hooks"; then
    green "[OK] PostToolUse hooks configured (Edit quality + Write dedup)"
  else
    yellow "[MISSING] PostToolUse hooks not fully configured"
  fi

  if settings_check "${SETTINGS_FILE}" "full-hooks"; then
    green "[OK] Full profile hooks configured (Stop gate + Build check + Learn evaluator)"
  else
    yellow "[INFO] Full profile hooks not configured (current install may be core profile)"
  fi
}

clean_claude_home_installation() {
  if [[ -f "${CLAUDE_DIR}/CLAUDE.md" ]]; then
    local result
    result=$(python3 "${CLAUDE_MD_HELPER}" remove "${CLAUDE_DIR}/CLAUDE.md" 2>/dev/null || echo "ERROR")
    case "${result}" in
      REMOVED|REMOVED_LEGACY) yellow "Removed VibeGuard rules from ~/.claude/CLAUDE.md" ;;
      NOT_FOUND) yellow "No VibeGuard rules found in ~/.claude/CLAUDE.md" ;;
      *) red "Failed to clean CLAUDE.md" ;;
    esac
  fi

  rm -f "${CLAUDE_DIR}/commands/vibeguard" 2>/dev/null || rm -rf "${CLAUDE_DIR}/commands/vibeguard" 2>/dev/null || true
  rm -f "${CLAUDE_DIR}/skills/vibeguard"
  rm -f "${CLAUDE_DIR}/skills/auto-optimize"
  rm -f "${CLAUDE_DIR}/skills/strategic-compact"
  rm -f "${CLAUDE_DIR}/skills/eval-harness"
  rm -f "${CLAUDE_DIR}/skills/iterative-retrieval"

  local agent
  for agent in "${REPO_DIR}"/agents/*.md; do
    [[ -f "${agent}" ]] || continue
    rm -f "${CLAUDE_DIR}/agents/$(basename "${agent}")"
  done
  rmdir "${CLAUDE_DIR}/agents" 2>/dev/null || true

  local profile
  for profile in "${REPO_DIR}"/context-profiles/*.md; do
    [[ -f "${profile}" ]] || continue
    rm -f "${CLAUDE_DIR}/context-profiles/$(basename "${profile}")"
  done
  rmdir "${CLAUDE_DIR}/context-profiles" 2>/dev/null || true

  if [[ -d "${HOME}/.claude/rules/vibeguard" ]]; then
    rm -rf "${HOME}/.claude/rules/vibeguard"
    yellow "Removed native rules from ~/.claude/rules/vibeguard/"
  fi

  if [[ -f "${SETTINGS_FILE}" ]]; then
    local clean_result
    if clean_result=$(settings_remove "${SETTINGS_FILE}" 2>/dev/null); then
      if [[ "${clean_result}" == "CHANGED" ]]; then
        yellow "Removed VibeGuard hooks and legacy MCP entries from settings.json"
      fi
    fi
  fi
}

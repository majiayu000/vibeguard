#!/usr/bin/env bash

_force_overwrite_enabled() {
  [[ "${VIBEGUARD_SETUP_FORCE_OVERWRITE:-0}" == "1" ]]
}

_protect_rule_file_overwrite() {
  local src="$1" dest="$2" label="$3"
  [[ -e "${dest}" && ! -L "${dest}" ]] || return 0

  if [[ -f "${src}" ]] && cmp -s "${src}" "${dest}"; then
    rm -f "${dest}"
    return 0
  fi

  if _force_overwrite_enabled; then
    yellow "  FORCE: replacing local rule copy ${dest}"
    rm -f "${dest}"
    return 0
  fi

  red "  ERROR: refusing to overwrite modified local rule file: ${dest}"
  red "  Re-run with --force-overwrite only if this local ${label} rule copy should be replaced."
  return 1
}

_remove_rule_subtree_if_safe() {
  local src_dir="$1" dest_dir="$2" label="$3"
  [[ -d "${dest_dir}" ]] || return 0

  local file rel src_file
  while IFS= read -r file; do
    [[ -e "${file}" || -L "${file}" ]] || continue
    [[ -L "${file}" ]] && continue
    rel="${file#"${dest_dir}/"}"
    src_file="${src_dir}/${rel}"
    if [[ -f "${src_file}" ]] && cmp -s "${src_file}" "${file}"; then
      continue
    fi
    if _force_overwrite_enabled; then
      continue
    fi
    red "  ERROR: refusing to remove modified local rule file: ${file}"
    red "  Re-run with --force-overwrite only if this local ${label} rule tree should be replaced."
    return 1
  done < <(find "${dest_dir}" \( -type f -o -type l \) 2>/dev/null)

  rm -rf "${dest_dir}"
}

_install_claude_skill_link() {
  local src="$1" dst="$2" source_path="$3" skill="$4"
  safe_symlink "${src}" "${dst}"
  state_record_file "${dst}" "${source_path}" "symlink"
  green "  ${skill} -> ~/.claude/skills/${skill}"
}

_check_command_symlink() {
  local link="$1" expected_target="$2" label="$3"
  if [[ -L "${link}" ]]; then
    local actual_target
    actual_target="$(readlink "${link}")"
    if [[ ! -e "${link}" ]]; then
      red "[BROKEN] ${label} symlink target missing: ${actual_target}"
    elif [[ "${actual_target}" != "${expected_target}" ]]; then
      red "[BROKEN] ${label} symlink target drift: ${actual_target} (expected: ${expected_target})"
    else
      green "[OK] ${label} symlinked to ~/.claude/commands/"
    fi
  elif [[ -e "${link}" ]]; then
    red "[BROKEN] ${label} path is not a symlink: ${link}"
  else
    red "[MISSING] ${label} not in ~/.claude/commands/"
  fi
}

_check_claude_skill_symlink() {
  local link="$1" expected_target="$2" skill="$3"
  if [[ -L "${link}" ]]; then
    local actual_target
    actual_target="$(readlink "${link}" 2>/dev/null || true)"
    if [[ -z "${actual_target}" ]]; then
      red "[BROKEN] ${skill} skill symlink target cannot be read: ${link}"
    elif [[ "${actual_target}" != "${expected_target}" ]]; then
      red "[BROKEN] ${skill} skill symlink target drift: ${actual_target} (expected: ${expected_target})"
    elif [[ ! -e "${link}" ]]; then
      red "[BROKEN] ${skill} skill symlink target missing: ${actual_target}"
    else
      green "[OK] ${skill} skill symlinked to ~/.claude/skills/"
    fi
  elif [[ -e "${link}" ]]; then
    red "[BROKEN] ${skill} skill path is not a symlink: ${link}"
  else
    red "[MISSING] ${skill} skill not in ~/.claude/skills/"
  fi
}

_check_claude_rule_symlink_targets() {
  local rules_dest="${HOME}/.claude/rules/vibeguard"
  local checked_count=0 broken_count=0
  local rule_links source_path dest_rel label link expected_target actual_target

  rule_links="$(manifest_rule_links_checked "")" || return 1
  while IFS=$'\t' read -r source_path dest_rel label; do
    [[ -n "${source_path}" && -n "${dest_rel}" && -n "${label}" ]] || continue
    link="${rules_dest}/${dest_rel}"
    [[ -L "${link}" ]] || continue
    checked_count=$((checked_count + 1))
    expected_target="${REPO_DIR}/${source_path}"
    actual_target="$(readlink "${link}" 2>/dev/null || true)"
    if [[ -z "${actual_target}" ]]; then
      red "[BROKEN] Native rule symlink target cannot be read: ${link}"
      broken_count=$((broken_count + 1))
    elif [[ "${actual_target}" != "${expected_target}" ]]; then
      red "[BROKEN] Native rule symlink target drift: ${link} -> ${actual_target} (expected: ${expected_target})"
      broken_count=$((broken_count + 1))
    elif [[ ! -e "${link}" ]]; then
      red "[BROKEN] Native rule symlink target missing: ${link} -> ${actual_target}"
      broken_count=$((broken_count + 1))
    fi
  done <<< "${rule_links}"

  if [[ "${checked_count}" -gt 0 && "${broken_count}" -eq 0 ]]; then
    green "[OK] Native rule symlink targets match current repo"
  fi
}

_rule_label_is_selected() {
  local label="$1" selected_labels="$2"
  while IFS= read -r selected_label; do
    [[ "${selected_label}" == "${label}" ]] && return 0
  done <<< "${selected_labels}"
  return 1
}

_rule_dest_is_declared() {
  local dest_rel="$1" rule_links="$2"
  printf '%s\n' "${rule_links}" \
    | awk -F '\t' -v dest_rel="${dest_rel}" '$2 == dest_rel { found = 1 } END { exit(found ? 0 : 1) }'
}

_cleanup_unlisted_rule_files() {
  local dest_dir="$1" label="$2" rule_links="$3"
  [[ -d "${dest_dir}" ]] || return 0

  local file rel actual_target
  while IFS= read -r file; do
    [[ -e "${file}" || -L "${file}" ]] || continue
    rel="${file#"${dest_dir}/"}"
    rel="${label}/${rel}"
    if _rule_dest_is_declared "${rel}" "${rule_links}"; then
      continue
    fi
    if [[ -L "${file}" ]]; then
      actual_target="$(readlink "${file}" 2>/dev/null || true)"
      if [[ -z "${actual_target}" || "${actual_target}" == "${REPO_DIR}/rules/claude-rules/"* || ! -e "${file}" ]]; then
        yellow "  Removed stale manifest rule symlink: ${file}"
        rm -f "${file}"
      else
        yellow "  Preserved unmanaged rule symlink not present in manifest: ${file} -> ${actual_target}"
      fi
      continue
    fi
    if _force_overwrite_enabled; then
      yellow "  FORCE: removing stale local rule copy ${file}"
      rm -f "${file}"
    else
      red "  ERROR: refusing to remove local rule file not present in manifest: ${file}"
      red "  Re-run with --force-overwrite only if this local ${label} rule copy should be removed."
      return 1
    fi
  done < <(find "${dest_dir}" \( -type f -o -type l \) -name "*.md" 2>/dev/null)
}

_install_manifest_rule_file() {
  local source_path="$1" dest_rel="$2" label="$3" rules_dest="$4"
  local src="${REPO_DIR}/${source_path}"
  local dest="${rules_dest}/${dest_rel}"

  mkdir -p "$(dirname "${dest}")"
  _protect_rule_file_overwrite "${src}" "${dest}" "${label}" || return 1
  ln -sf "${src}" "${dest}"
  state_record_file "${dest}" "${source_path}" "symlink"
}

_clean_command_symlink_if_managed() {
  local link="$1" expected_target="$2" label="$3"
  if [[ -L "${link}" ]]; then
    local actual_target
    actual_target="$(readlink "${link}")"
    if [[ "${actual_target}" == "${expected_target}" ]]; then
      rm -f "${link}" 2>/dev/null || true
    else
      yellow "Preserved unmanaged ${label} symlink: ${link} -> ${actual_target}"
    fi
  elif [[ -e "${link}" ]]; then
    yellow "Preserved unmanaged ${label} path: ${link}"
  fi
}

install_claude_home_assets() {
  echo "Step 2: Install Claude Code skills"
  install_manifest_skills "~/.claude/skills/" "${CLAUDE_DIR}/skills" _install_claude_skill_link || return 1
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
  install_context_profiles "${CLAUDE_DIR}/context-profiles" "~/.claude/context-profiles"
  echo

  echo "Step 5: Install custom commands"
  mkdir -p "${CLAUDE_DIR}/commands"
  safe_symlink "${REPO_DIR}/.claude/commands/vibeguard" "${CLAUDE_DIR}/commands/vibeguard"
  state_record_file "${CLAUDE_DIR}/commands/vibeguard" ".claude/commands/vibeguard" "symlink"
  green "  vibeguard commands -> ~/.claude/commands/vibeguard"
  safe_symlink "${REPO_DIR}/.claude/commands/vg" "${CLAUDE_DIR}/commands/vg"
  state_record_file "${CLAUDE_DIR}/commands/vg" ".claude/commands/vg" "symlink"
  green "  vg shortcut commands -> ~/.claude/commands/vg"
  echo

  echo "Step 5.5: Install native rules (symlinked)"
  local rules_dest="${HOME}/.claude/rules/vibeguard"
  local rule_links selected_labels all_labels source_path dest_rel label installed_count
  rule_links="$(manifest_rule_links_checked "${LANGUAGES:-}")" || return 1
  selected_labels="$(manifest_rule_labels_checked "${LANGUAGES:-}")" || return 1
  all_labels="$(manifest_rule_labels_checked "")" || return 1

  mkdir -p "${rules_dest}"
  while IFS= read -r label; do
    [[ -n "${label}" ]] || continue
    if _rule_label_is_selected "${label}" "${selected_labels}"; then
      continue
    fi
    if [[ -d "${rules_dest}/${label}" ]]; then
      _remove_rule_subtree_if_safe "${REPO_DIR}/rules/claude-rules/${label}" "${rules_dest}/${label}" "${label}" || return 1
      yellow "  ${label}/ removed (not in --languages filter)"
    fi
  done <<< "${all_labels}"

  while IFS= read -r label; do
    [[ -n "${label}" ]] || continue
    _cleanup_unlisted_rule_files "${rules_dest}/${label}" "${label}" "${rule_links}" || return 1
  done <<< "${selected_labels}"

  installed_count=0
  while IFS=$'\t' read -r source_path dest_rel label; do
    [[ -n "${source_path}" && -n "${dest_rel}" && -n "${label}" ]] || continue
    _install_manifest_rule_file "${source_path}" "${dest_rel}" "${label}" "${rules_dest}" || return 1
    installed_count=$((installed_count + 1))
  done <<< "${rule_links}"
  green "  manifest rules -> ~/.claude/rules/vibeguard/ (${installed_count} files, symlinked)"

  if [[ -d "${rules_dest}" ]]; then
    if [[ -d "${VIBEGUARD_HOME}/user-rules" ]]; then
      local local_rules_count
      local_rules_count=$(find "${VIBEGUARD_HOME}/user-rules" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
      if [[ "${local_rules_count}" -gt 0 ]]; then
        mkdir -p "${rules_dest}/custom"
        for f in "${VIBEGUARD_HOME}/user-rules/"*.md; do
          [[ -f "$f" ]] || continue
          ln -sf "$f" "${rules_dest}/custom/$(basename "$f")"
        done
        state_record_tree "${rules_dest}/custom" "user-rules"
        green "  custom/ -> ~/.claude/rules/vibeguard/custom/ (${local_rules_count} user rules, symlinked)"
      fi
    fi
  else
    yellow "  SKIP native rules (destination not available: ${rules_dest})"
  fi
  echo
}

claude_rule_id_count() {
  vibeguard_rule_id_count "$1"
}

claude_rule_count_for_banner() {
  local rules_dest="${HOME}/.claude/rules/vibeguard"
  local total=0 dir_count rule_links source_path dest_rel label

  if [[ "${VIBEGUARD_SETUP_DRY_RUN}" != "1" && -d "${rules_dest}" ]]; then
    claude_rule_id_count "${rules_dest}"
    return 0
  fi

  rule_links="$(manifest_rule_links_checked "${LANGUAGES:-}")" || return 1
  while IFS=$'\t' read -r source_path dest_rel label; do
    [[ -n "${source_path}" && -n "${dest_rel}" && -n "${label}" ]] || continue
    dir_count=$(claude_rule_id_count "${REPO_DIR}/${source_path}")
    total=$((total + dir_count))
  done <<< "${rule_links}"
  if [[ -d "${HOME}/.vibeguard/user-rules" ]]; then
    dir_count=$(claude_rule_id_count "${HOME}/.vibeguard/user-rules")
    total=$((total + dir_count))
  fi
  printf '%s\n' "${total}"
}

configure_claude_home_runtime() {
  echo "Step 9: Configure Claude hooks (${PROFILE} profile)"
  local settings_diff
  if ! settings_diff=$(settings_upsert_diff "${SETTINGS_FILE}" "${PROFILE}" 2>&1); then
    red "  Failed to compute settings.json diff"
    return 1
  fi
  if ! confirm_high_context_write "~/.claude/settings.json" "${settings_diff}"; then
    if [[ "${VIBEGUARD_SETUP_DRY_RUN}" == "1" ]]; then
      echo
      return 0
    fi
    return 1
  fi
  if settings_upsert "${SETTINGS_FILE}" "${PROFILE}" >/dev/null; then
    state_record_file "${SETTINGS_FILE}" "generated/settings.json" "copy"
    green "  Hooks configured in ~/.claude/settings.json (${PROFILE})"
  else
    red "  Failed to configure settings.json"
  fi
  echo
}

inject_claude_home_rules() {
  echo "Step 10: Update VibeGuard rules in CLAUDE.md"
  inject_vibeguard_rules "${CLAUDE_DIR}/CLAUDE.md" "~/.claude/CLAUDE.md" "generated/CLAUDE.md"
}

check_claude_home_installation() {
  if [[ -f "${CLAUDE_DIR}/CLAUDE.md" ]] && grep -q "VibeGuard" "${CLAUDE_DIR}/CLAUDE.md" 2>/dev/null; then
    green "[OK] VibeGuard rules in ~/.claude/CLAUDE.md"
  else
    red "[MISSING] VibeGuard rules not in ~/.claude/CLAUDE.md"
  fi

  local link skill_links source_path skill
  skill_links="$(manifest_skill_links_checked "~/.claude/skills/")" || return 1
  while IFS=$'\t' read -r source_path skill; do
    [[ -n "${source_path}" && -n "${skill}" ]] || continue
    link="${CLAUDE_DIR}/skills/${skill}"
    _check_claude_skill_symlink "${link}" "${REPO_DIR}/${source_path}" "${skill}"
  done <<< "${skill_links}"

  _check_command_symlink \
    "${CLAUDE_DIR}/commands/vibeguard" \
    "${REPO_DIR}/.claude/commands/vibeguard" \
    "vibeguard commands"
  _check_command_symlink \
    "${CLAUDE_DIR}/commands/vg" \
    "${REPO_DIR}/.claude/commands/vg" \
    "vg shortcut commands"

  local expected_agent_count=0 missing_agent_count=0 unmanaged_agent_count=0
  local missing_agents="" unmanaged_agents="" agent name installed_agent
  for agent in "${REPO_DIR}"/agents/*.md; do
    [[ -f "${agent}" ]] || continue
    expected_agent_count=$((expected_agent_count + 1))
    name="$(basename "${agent}")"
    if [[ ! -f "${CLAUDE_DIR}/agents/${name}" ]]; then
      missing_agent_count=$((missing_agent_count + 1))
      missing_agents="${missing_agents}${missing_agents:+, }${name}"
    fi
  done
  if [[ "${expected_agent_count}" -eq 0 ]]; then
    yellow "[MISSING] no VibeGuard agent sources found in repo agents/"
  elif [[ "${missing_agent_count}" -eq 0 ]]; then
    green "[OK] ${expected_agent_count} VibeGuard agents installed in ~/.claude/agents/"
  else
    red "[MISSING] ${missing_agent_count}/${expected_agent_count} VibeGuard agent(s) missing in ~/.claude/agents/: ${missing_agents}"
  fi
  if [[ -d "${CLAUDE_DIR}/agents" ]]; then
    for installed_agent in "${CLAUDE_DIR}"/agents/*.md; do
      [[ -f "${installed_agent}" ]] || continue
      name="$(basename "${installed_agent}")"
      if [[ ! -f "${REPO_DIR}/agents/${name}" ]]; then
        unmanaged_agent_count=$((unmanaged_agent_count + 1))
        unmanaged_agents="${unmanaged_agents}${unmanaged_agents:+, }${name}"
      fi
    done
    if [[ "${unmanaged_agent_count}" -gt 0 ]]; then
      yellow "[INFO] ${unmanaged_agent_count} unmanaged Claude agent(s) present in ~/.claude/agents/: ${unmanaged_agents}"
    fi
  fi

  if [[ -d "${CLAUDE_DIR}/context-profiles" ]] && [[ -n "$(ls -A "${CLAUDE_DIR}/context-profiles" 2>/dev/null)" ]]; then
    green "[OK] context profiles installed in ~/.claude/context-profiles/"
  else
    yellow "[MISSING] context profiles not in ~/.claude/context-profiles/"
  fi

  local rules_dest="${HOME}/.claude/rules/vibeguard"
  local rule_file_count actual_rule_count claude_md declared_count
  local symlink_count copy_count
  if [[ -d "${rules_dest}" ]]; then
    rule_file_count=$(find "${rules_dest}" -name "*.md" \( -type f -o -type l \) 2>/dev/null | wc -l | tr -d ' ')
    symlink_count=$(find "${rules_dest}" -name "*.md" -type l 2>/dev/null | wc -l | tr -d ' ')
    copy_count=$((rule_file_count - symlink_count))
    if [[ "${rule_file_count}" -ge 7 ]]; then
      green "[OK] ${rule_file_count} native rule files in ~/.claude/rules/vibeguard/ (${symlink_count} symlinked)"
    else
      yellow "[PARTIAL] Only ${rule_file_count} native rule files (expected 7+)"
    fi
    if [[ "${copy_count}" -gt 0 ]]; then
      yellow "[DRIFT] ${copy_count} rule files are copies instead of symlinks — re-run setup.sh to fix"
    fi
    _check_claude_rule_symlink_targets

    actual_rule_count=$(claude_rule_id_count "${rules_dest}")
    claude_md="${CLAUDE_DIR}/CLAUDE.md"
    if [[ -f "${claude_md}" ]]; then
      if declared_count=$(vibeguard_managed_rule_banner_count "${claude_md}"); then
        if [[ "${actual_rule_count}" -eq "${declared_count}" ]]; then
          green "[OK] Rule count in sync: ${actual_rule_count} rules"
        else
          yellow "[DRIFT] CLAUDE.md declares ${declared_count} rules, actual: ${actual_rule_count}"
          yellow "[INFO] Re-run 'bash setup.sh' to repair the rule count banner in ~/.claude/CLAUDE.md"
        fi
      else
        yellow "[DRIFT] CLAUDE.md missing VibeGuard rule count banner, actual: ${actual_rule_count}"
        yellow "[INFO] Re-run 'bash setup.sh' to repair the rule count banner in ~/.claude/CLAUDE.md"
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
    green "[OK] Full profile hooks configured (Stop signal + Build check + Learn evaluator)"
  else
    yellow "[INFO] Full profile hooks not configured (current install may be core profile)"
  fi

  local stale_hooks_report
  if stale_hooks_report="$(settings_stale_hooks_report "${SETTINGS_FILE}" 2>&1)"; then
    :
  else
    while IFS= read -r line; do
      [[ -n "${line}" ]] && red "[BROKEN] ${line}"
    done <<< "${stale_hooks_report}"
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

  _clean_command_symlink_if_managed \
    "${CLAUDE_DIR}/commands/vibeguard" \
    "${REPO_DIR}/.claude/commands/vibeguard" \
    "vibeguard commands"
  _clean_command_symlink_if_managed \
    "${CLAUDE_DIR}/commands/vg" \
    "${REPO_DIR}/.claude/commands/vg" \
    "vg shortcut commands"
  local skill_links source_path skill
  skill_links="$(manifest_skill_links_for_cleanup "~/.claude/skills/")"
  while IFS=$'\t' read -r source_path skill; do
    [[ -n "${source_path}" && -n "${skill}" ]] || continue
    rm -f "${CLAUDE_DIR}/skills/${skill}"
  done <<< "${skill_links}"
  cleanup_retired_manifest_skill_links "~/.claude/skills/" "${CLAUDE_DIR}/skills"

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

#!/usr/bin/env bash
# Managed workflow skill lifecycle helpers (GH719).

disabled_skills_source_label() {
  if [[ -n "${VIBEGUARD_DISABLED_SKILLS+x}" ]]; then
    printf '%s\n' "temporary VIBEGUARD_DISABLED_SKILLS override"
  elif [[ -n "${_VG_CONFIG_FILE:-}" ]]; then
    printf '%s\n' "${_VG_CONFIG_FILE}"
  elif [[ -n "${VIBEGUARD_CONFIG_FILE:-}" ]]; then
    printf '%s\n' "${VIBEGUARD_CONFIG_FILE}"
  elif [[ -n "${VIBEGUARD_LOG_DIR:-}" ]]; then
    printf '%s\n' "${VIBEGUARD_LOG_DIR%/}/config.json"
  else
    printf '%s\n' "~/.vibeguard/config.json"
  fi
}

disabled_skills() {
  if [[ -n "${_VG_DISABLED_SKILLS_CACHE+x}" ]]; then
    printf '%s' "${_VG_DISABLED_SKILLS_CACHE}"
    return 0
  fi
  local output
  if ! output="$(setup_runtime runtime-config-get-list \
    VIBEGUARD_DISABLED_SKILLS disabled_skills 2>&1)"; then
    red "  ERROR: cannot read disabled_skills from $(disabled_skills_source_label)" >&2
    while IFS= read -r line; do
      [[ -n "${line}" ]] && red "  ${line}" >&2
    done <<< "${output}"
    return 1
  fi
  _VG_DISABLED_SKILLS_CACHE="${output}"
  printf '%s' "${_VG_DISABLED_SKILLS_CACHE}"
}

skill_is_disabled() {
  local skill="$1" disabled entry
  disabled="$(disabled_skills)" || return 2
  while IFS= read -r entry; do
    [[ "${entry}" == "${skill}" ]] && return 0
  done <<< "${disabled}"
  return 1
}

remove_disabled_skill() {
  local dest="$1" skill="$2" dest_dir="$3" source_path="$4"
  local dest_parent dest_parent_abs dest_dir_abs ownership_rc quarantine="" attempt
  [[ -e "${dest}" || -L "${dest}" ]] || return 0

  dest_parent="$(dirname "${dest}")"
  if [[ ! -d "${dest_parent}" || ! -d "${dest_dir}" ]]; then
    red "  ERROR: refusing to remove disabled skill from an invalid parent: ${dest}"
    return 1
  fi
  dest_parent_abs="$(cd "${dest_parent}" && pwd -P)" || return 1
  dest_dir_abs="$(cd "${dest_dir}" && pwd -P)" || return 1
  if [[ "${dest_parent_abs}" != "${dest_dir_abs}" ]]; then
    red "  ERROR: refusing to remove disabled skill outside ${dest_dir}: ${dest}"
    return 1
  fi

  if state_managed_tree_owned "${dest}" "${source_path}"; then
    :
  else
    ownership_rc=$?
    if [[ "${ownership_rc}" -eq 2 ]]; then
      red "  ERROR: cannot verify ownership for disabled skill ${skill}"
    else
      red "  ERROR: refusing to remove ${skill}; current tree is not an exact VibeGuard-managed copy"
    fi
    return 1
  fi

  # Move the verified tree out of its public name atomically, then verify that
  # exact identity against the original tracked root before deleting it.
  for attempt in {1..10}; do
    quarantine="${dest_parent}/.${skill}.vibeguard-remove.$$-${RANDOM:-0}-${attempt}"
    [[ ! -e "${quarantine}" && ! -L "${quarantine}" ]] || continue
    if mv -- "${dest}" "${quarantine}"; then
      break
    fi
    quarantine=""
  done
  if [[ -z "${quarantine}" ]]; then
    red "  ERROR: failed to quarantine disabled skill ${skill}: ${dest}"
    return 1
  fi

  if state_managed_tree_owned "${quarantine}" "${source_path}" "${dest}"; then
    :
  else
    ownership_rc=$?
    if [[ ! -e "${dest}" && ! -L "${dest}" ]] \
      && mv -- "${quarantine}" "${dest}"; then
      quarantine=""
    fi
    if [[ "${ownership_rc}" -eq 2 ]]; then
      red "  ERROR: cannot reverify quarantined ownership for disabled skill ${skill}"
    else
      red "  ERROR: disabled skill changed during removal; preserved without deletion: ${skill}"
    fi
    if [[ -n "${quarantine}" ]]; then
      red "  ERROR: concurrent replacement blocked automatic restore; preserved at ${quarantine}"
    fi
    return 1
  fi
  if ! rm -rf -- "${quarantine}"; then
    red "  ERROR: failed to remove disabled skill ${skill}: ${dest}"
    return 1
  fi
  if [[ -e "${dest}" || -L "${dest}" ]]; then
    red "  ERROR: concurrent replacement preserved at disabled skill path: ${dest}"
    return 1
  fi
  yellow "  REMOVED ${skill} (disabled via $(disabled_skills_source_label))"
}

report_skill_restore() {
  local dest="$1" skill="$2" tracked_rc
  [[ -e "${dest}" || -L "${dest}" ]] && return 0
  declare -F state_is_tracked_path >/dev/null || return 0
  if state_is_tracked_path "${dest}"; then
    yellow "  RESTORING ${skill}: previously installed by VibeGuard and since deleted."
    yellow "    To keep it removed, add \"${skill}\" to \"disabled_skills\" in $(disabled_skills_source_label)."
    return 0
  fi
  tracked_rc=$?
  [[ "${tracked_rc}" -eq 1 ]] && return 0
  return "${tracked_rc}"
}

install_manifest_skills() {
  local target_uri="$1" dest_dir="$2" install_fn="$3" apply_disabled="${4:-0}"
  local skill_links source_path skill

  mkdir -p "${dest_dir}"
  skill_links="$(manifest_skill_links_checked "${target_uri}")" || return 1
  if [[ "${apply_disabled}" == "1" ]]; then
    disabled_skills >/dev/null || return 1
  fi
  while IFS=$'\t' read -r source_path skill; do
    [[ -n "${source_path}" && -n "${skill}" ]] || continue
    if [[ "${apply_disabled}" == "1" ]] && skill_is_disabled "${skill}"; then
      remove_disabled_skill \
        "${dest_dir}/${skill}" "${skill}" "${dest_dir}" "${source_path}" || return 1
      yellow "  SKIP ${skill} (disabled via $(disabled_skills_source_label))"
      continue
    fi
    if [[ -d "${REPO_DIR}/${source_path}" ]]; then
      if [[ "${apply_disabled}" == "1" ]]; then
        report_skill_restore "${dest_dir}/${skill}" "${skill}" || return 1
      fi
      "${install_fn}" \
        "${REPO_DIR}/${source_path}" "${dest_dir}/${skill}" "${source_path}" "${skill}" || return 1
    else
      yellow "  SKIP ${skill} (source not found: ${source_path})"
    fi
  done <<< "${skill_links}"
}

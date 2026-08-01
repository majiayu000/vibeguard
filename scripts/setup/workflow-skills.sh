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
  local dest_parent dest_parent_abs dest_dir_abs quarantine_output quarantine_path

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

  if ! quarantine_output="$(setup_runtime setup-state-quarantine-managed-tree \
    "${STATE_FILE}" "${STATE_PREVIOUS_FILE}" "${dest}" "${source_path}" 2>&1)"; then
    red "  ERROR: failed to quarantine disabled skill ${skill}: ${dest}"
    while IFS= read -r line; do
      [[ -n "${line}" ]] && red "  ${line}"
    done <<< "${quarantine_output}"
    return 1
  fi
  case "${quarantine_output}" in
    ABSENT) ;;
    $'QUARANTINED\t'*)
      quarantine_path="${quarantine_output#*$'\t'}"
      [[ -n "${quarantine_path}" ]] || {
        red "  ERROR: invalid quarantine locator for disabled skill ${skill}"
        return 1
      }
      yellow "  QUARANTINED ${skill} at ${quarantine_path} (disabled via $(disabled_skills_source_label))"
      ;;
    *)
      red "  ERROR: invalid managed-tree quarantine result for disabled skill ${skill}"
      return 1
      ;;
  esac
  if [[ -e "${dest}" || -L "${dest}" ]]; then
    red "  ERROR: concurrent replacement preserved at disabled skill path: ${dest}"
    return 1
  fi
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

release_reenabled_skill() {
  local dest="$1" skill="$2" source_path="$3" release_output
  if ! release_output="$(setup_runtime setup-state-release-quarantined-tree \
    "${STATE_FILE}" "${STATE_PREVIOUS_FILE}" "${dest}" "${source_path}" 2>&1)"; then
    red "  ERROR: failed to release retained quarantine after re-enabling ${skill}"
    while IFS= read -r line; do
      [[ -n "${line}" ]] && red "  ${line}"
    done <<< "${release_output}"
    return 1
  fi
  case "${release_output}" in
    ABSENT) ;;
    RELEASED)
      yellow "  RE-ENABLED ${skill} from the canonical source; prior quarantine retained."
      ;;
    *)
      red "  ERROR: invalid quarantine release result for re-enabled skill ${skill}"
      return 1
      ;;
  esac
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
      if [[ "${apply_disabled}" == "1" ]]; then
        release_reenabled_skill "${dest_dir}/${skill}" "${skill}" "${source_path}" || return 1
      fi
    else
      yellow "  SKIP ${skill} (source not found: ${source_path})"
    fi
  done <<< "${skill_links}"
}

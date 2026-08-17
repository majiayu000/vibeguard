#!/usr/bin/env bash
# Managed workflow skill lifecycle helpers (GH719).

retired_codex_skill_hash() {
  case "$1" in
    implx) printf '%s\n' '36df08e0784dcb71a2506f3e7197e2de0a2b846b0555b31778ad45d4bf0e4e57' ;;
    specrail-check-impl-against-spec) printf '%s\n' 'a1e03c454474bd1117aea05e31273d54794111d2e809fee641e39c70f4a7b29e' ;;
    specrail-diagnose-ci) printf '%s\n' 'a59df025007feafdbe922f1ad1a5d3210e4064f493c8e85a0e76f4c238786565' ;;
    specrail-implement-queue) printf '%s\n' 'ac6b121238f73a9dc2767a8ffaf8779e0ee54d20ceb4ea054672d72943f4d769' ;;
    specrail-implement) printf '%s\n' 'cc8bc0da7a0582b2a58d5a6161c623681fb7b514941569ae537cfef87e58d1e8' ;;
    specrail-install) printf '%s\n' '96986efdaa7f18527ab3303e8168ebb635b04b57a3ee73be49f30364665edea4' ;;
    specrail-plan-tasks) printf '%s\n' '9d8219b4d04e44c40b117847057b436b7de26a5ca90a9e7b8d2d5c9989b29c13' ;;
    specrail-pr-gate) printf '%s\n' 'cd38a82e566b6981299a6496ead086cabcb228519c92fbc0fe59fdf31b3d540a' ;;
    specrail-release-note) printf '%s\n' 'e341a940648f058c45be590661728f3adcd66a925343a9922e7f6434606f3e0b' ;;
    specrail-review-pr) printf '%s\n' '715a36929fec5bf70bfd032e744390ddbb5c5f187d07f242bcae7297b71834df' ;;
    specrail-triage-issue) printf '%s\n' '78b463f634434cb86ff80b3af3d174f8c78f2da0b3d3a0144888751f0a8eb437' ;;
    specrail-workflow) printf '%s\n' 'cdb2627affb595bb23097ec67632c7ece5902f60a51ee5fd29b0ef48065d2aff' ;;
    specrail-write-product-spec) printf '%s\n' 'ef9180215502e4c8312f613d6cc38c984b3f0d84c4910d93d6b07a5171a3dc48' ;;
    specrail-write-tech-spec) printf '%s\n' 'e2de93cb893af5a4a17579481043edad6b1a5a1e49092ef8e3567bdf4ae395ed' ;;
    *) return 1 ;;
  esac
}

retire_legacy_codex_skills() {
  local skills_dir="$1" quarantine_dir="$2" resolved_skills_dir
  [[ ! -e "${skills_dir}" && ! -L "${skills_dir}" ]] && return 0
  if [[ ! -d "${skills_dir}" ]]; then
    red "  ERROR: Codex skills root is not a real directory: ${skills_dir}"
    return 1
  fi
  if ! resolved_skills_dir="$(cd "${skills_dir}" && pwd -P)"; then
    red "  ERROR: cannot resolve Codex skills root: ${skills_dir}"
    return 1
  fi
  skills_dir="${resolved_skills_dir}"
  if [[ -L "${quarantine_dir}" || ( -e "${quarantine_dir}" && ! -d "${quarantine_dir}" ) ]]; then
    red "  ERROR: retired Codex skill quarantine is not a real directory: ${quarantine_dir}"
    return 1
  fi

  local skill source skill_file expected_hash actual_hash target suffix entry
  local -a entries
  for skill in \
    implx \
    specrail-check-impl-against-spec \
    specrail-diagnose-ci \
    specrail-implement-queue \
    specrail-implement \
    specrail-install \
    specrail-plan-tasks \
    specrail-pr-gate \
    specrail-release-note \
    specrail-review-pr \
    specrail-triage-issue \
    specrail-workflow \
    specrail-write-product-spec \
    specrail-write-tech-spec; do
    source="${skills_dir}/${skill}"
    [[ ! -e "${source}" && ! -L "${source}" ]] && continue
    if [[ -L "${source}" || ! -d "${source}" ]]; then
      yellow "  SKIP modified or user-owned retired Codex skill: ${source}"
      continue
    fi

    entries=()
    for entry in "${source}"/* "${source}"/.[!.]* "${source}"/..?*; do
      [[ -e "${entry}" || -L "${entry}" ]] || continue
      entries+=("${entry}")
    done
    skill_file="${source}/SKILL.md"
    if [[ "${#entries[@]}" -ne 1 || "${entries[0]}" != "${skill_file}" || ! -f "${skill_file}" || -L "${skill_file}" ]]; then
      yellow "  SKIP modified or user-owned retired Codex skill: ${source}"
      continue
    fi

    expected_hash="$(retired_codex_skill_hash "${skill}")" || return 1
    if ! actual_hash="$(setup_runtime_sha256_file "${skill_file}")"; then
      red "  ERROR: cannot hash retired Codex skill safely: ${skill_file}"
      return 1
    fi
    if [[ "${actual_hash}" != "${expected_hash}" ]]; then
      yellow "  SKIP modified or user-owned retired Codex skill: ${source}"
      continue
    fi

    mkdir -p "${quarantine_dir}"
    target="${quarantine_dir}/${skill}"
    suffix=1
    while [[ -e "${target}" || -L "${target}" ]]; do
      target="${quarantine_dir}/${skill}.${suffix}"
      suffix=$((suffix + 1))
    done
    mv "${source}" "${target}"
    yellow "  Retired legacy Codex skill: ${source} -> ${target}"
  done
}

retired_bundled_codex_skills() {
  printf '%s\t%s\n' \
    'skills/vibeguard' 'vibeguard' \
    'skills/agentsmd-audit' 'agentsmd-audit' \
    'skills/trajectory-review' 'trajectory-review' \
    'workflows/plan-flow' 'plan-flow' \
    'workflows/fixflow' 'fixflow' \
    'workflows/optflow' 'optflow' \
    'workflows/plan-mode' 'plan-mode' \
    'workflows/auto-optimize' 'auto-optimize'
}

retire_bundled_codex_skill_copies() {
  local skills_dir="$1" source_path skill dest owned_rc output quarantine
  [[ -d "${skills_dir}" ]] || return 0

  while IFS=$'\t' read -r source_path skill; do
    [[ -n "${source_path}" && -n "${skill}" ]] || continue
    dest="${skills_dir}/${skill}"
    [[ -e "${dest}" || -L "${dest}" ]] || continue
    [[ -d "${dest}" && ! -L "${dest}" ]] || continue

    if state_managed_tree_owned "${dest}" "${source_path}"; then
      owned_rc=0
    else
      owned_rc=$?
    fi
    if [[ "${owned_rc}" -eq 1 ]]; then
      yellow "  Preserved modified or user-owned retired Codex skill: ${dest}"
      continue
    elif [[ "${owned_rc}" -ne 0 ]]; then
      return "${owned_rc}"
    fi

    if ! output="$(setup_runtime setup-state-remove-managed-tree \
      "${STATE_FILE}" "${STATE_PREVIOUS_FILE}" "${dest}" "${source_path}" 2>&1)"; then
      red "  ERROR: failed to retire managed Codex skill ${skill}: ${dest}"
      while IFS= read -r line; do
        [[ -n "${line}" ]] && red "  ${line}"
      done <<< "${output}"
      return 1
    fi
    case "${output}" in
      ABSENT) ;;
      $'QUARANTINED\t'*)
        quarantine="${output#*$'\t'}"
        [[ -n "${quarantine}" ]] || return 1
        yellow "  Retired managed Codex skill: ${dest} -> ${quarantine}"
        ;;
      *)
        red "  ERROR: invalid retirement result for ${skill}: ${output}"
        return 1
        ;;
    esac
  done < <(retired_bundled_codex_skills)
}

clean_retired_bundled_codex_skill_copies() {
  # Clean must use the same atomic rename, post-rename ownership verification,
  # and durable transaction as setup. A direct rm after a separate ownership
  # check could delete a user replacement that races with clean.
  retire_bundled_codex_skill_copies "$1"
}

disabled_skills_project_source_label() {
  local output source detail cwd
  cwd="${REPO_DIR:-${PWD}}"
  output="$(setup_runtime config explain disabled_skills --cwd "${cwd}" --json 2>/dev/null)" || return 1
  source="$(printf '%s' "${output}" | setup_runtime json-field --strict source 2>/dev/null)" || return 1
  [[ "${source}" == "project_config" ]] || return 1
  detail="$(printf '%s' "${output}" | setup_runtime json-field --strict source_detail 2>/dev/null)" || return 1
  printf '%s\n' "${detail%%#\$.*}"
}

disabled_skills_project_config_path() {
  local cwd git_root candidate
  cwd="${REPO_DIR:-${PWD}}"
  if [[ -n "${VIBEGUARD_PROJECT_CONFIG:-}" && -f "${VIBEGUARD_PROJECT_CONFIG}" ]]; then
    printf '%s\n' "${VIBEGUARD_PROJECT_CONFIG}"
    return 0
  fi
  if git_root="$(git -C "${cwd}" rev-parse --show-toplevel 2>/dev/null)"; then
    candidate="${git_root}/.vibeguard.json"
    if [[ -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  fi
  candidate="${cwd%/}/.vibeguard.json"
  [[ -f "${candidate}" ]] || return 1
  printf '%s\n' "${candidate}"
}

disabled_skills_source_label() {
  local diagnostic="${1:-}" project_source
  if [[ -n "${VIBEGUARD_DISABLED_SKILLS+x}" ]]; then
    printf '%s\n' "temporary VIBEGUARD_DISABLED_SKILLS override"
  elif [[ "${diagnostic}" == *"VibeGuard project config invalid"* ]] &&
    project_source="$(disabled_skills_project_config_path)"; then
    printf '%s\n' "${project_source}"
  elif project_source="$(disabled_skills_project_source_label)"; then
    printf '%s\n' "${project_source}"
  elif [[ -n "${VG_INTERNAL_CONFIG_FILE:-}" ]]; then
    printf '%s\n' "${VG_INTERNAL_CONFIG_FILE}"
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
  if ! output="$(cd "${REPO_DIR}" && setup_runtime runtime-config-get-list \
    VIBEGUARD_DISABLED_SKILLS disabled_skills 2>&1)"; then
    red "  ERROR: cannot read disabled_skills from $(disabled_skills_source_label "${output}")" >&2
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
  local target_uri="$1" dest_dir="$2" install_fn="$3" apply_disabled="${4:-0}" allow_empty="${5:-0}"
  local skill_links source_path skill

  mkdir -p "${dest_dir}"
  skill_links="$(manifest_skill_links_checked "${target_uri}" "${allow_empty}")" || return 1
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

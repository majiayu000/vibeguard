#!/usr/bin/env bash
# VibeGuard Setup — shared variables and functions
# Sourced by install.sh, check.sh, clean.sh

REPO_DIR="${VIBEGUARD_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
CLAUDE_DIR="${HOME}/.claude"
CODEX_DIR="${HOME}/.codex"
SETTINGS_HELPER="${REPO_DIR}/scripts/lib/settings_json.py"
CODEX_HOOKS_HELPER="${REPO_DIR}/scripts/lib/codex_hooks_json.py"
CODEX_CONFIG_HELPER="${REPO_DIR}/scripts/lib/codex_config_toml.py"
MANIFEST_HELPER="${REPO_DIR}/scripts/lib/vibeguard_manifest.py"
CLAUDE_MD_HELPER="${REPO_DIR}/scripts/lib/claude_md.py"
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"
VIBEGUARD_SETUP_DRY_RUN="${VIBEGUARD_SETUP_DRY_RUN:-0}"
VIBEGUARD_SETUP_AUTO="${VIBEGUARD_SETUP_AUTO:-0}"
VIBEGUARD_SETUP_FORCE_OVERWRITE="${VIBEGUARD_SETUP_FORCE_OVERWRITE:-0}"

green() { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
red() { printf '\033[31m%s\033[0m\n' "$1"; }

settings_check() {
  local settings_file="$1" target="$2"
  [[ -f "${settings_file}" ]] || return 1
  python3 "${SETTINGS_HELPER}" check --settings-file "${settings_file}" --target "${target}" >/dev/null 2>&1
}

settings_stale_hooks_report() {
  local settings_file="$1"
  [[ -f "${settings_file}" ]] || return 0
  python3 "${SETTINGS_HELPER}" check-stale-hooks --settings-file "${settings_file}"
}

settings_upsert() {
  local settings_file="$1" profile="$2"
  local args=(upsert-vibeguard --settings-file "${settings_file}" --repo-dir "${REPO_DIR}" --profile "${profile}")
  if [[ "${VIBEGUARD_SETUP_FORCE_OVERWRITE}" == "1" ]]; then
    args+=(--force-overwrite)
  fi
  python3 "${SETTINGS_HELPER}" "${args[@]}"
}

settings_upsert_diff() {
  local settings_file="$1" profile="$2"
  local args=(upsert-vibeguard --dry-run --settings-file "${settings_file}" --repo-dir "${REPO_DIR}" --profile "${profile}")
  if [[ "${VIBEGUARD_SETUP_FORCE_OVERWRITE}" == "1" ]]; then
    args+=(--force-overwrite)
  fi
  python3 "${SETTINGS_HELPER}" "${args[@]}"
}

settings_remove() {
  local settings_file="$1"
  python3 "${SETTINGS_HELPER}" remove-vibeguard --settings-file "${settings_file}"
}

manifest_skill_links() {
  local target="$1"
  python3 "${MANIFEST_HELPER}" skill-links --target "${target}"
}

manifest_skill_links_checked() {
  local target="$1"
  local output
  if ! output="$(manifest_skill_links "${target}" 2>&1)"; then
    red "  ERROR: failed to enumerate manifest skills for ${target}" >&2
    while IFS= read -r line; do
      [[ -n "${line}" ]] && red "  ${line}" >&2
    done <<< "${output}"
    return 1
  fi
  if [[ -z "${output//[[:space:]]/}" ]]; then
    red "  ERROR: no manifest skills declared for ${target}" >&2
    return 1
  fi
  printf '%s\n' "${output}"
}

manifest_skill_links_for_cleanup() {
  local target="$1"
  local output
  if ! output="$(manifest_skill_links "${target}" 2>&1)"; then
    yellow "  WARN: failed to enumerate manifest skills for ${target}; skipping skill link cleanup" >&2
    while IFS= read -r line; do
      [[ -n "${line}" ]] && yellow "  ${line}" >&2
    done <<< "${output}"
    return 0
  fi
  if [[ -z "${output//[[:space:]]/}" ]]; then
    yellow "  WARN: no manifest skills declared for ${target}; skipping skill link cleanup" >&2
    return 0
  fi
  printf '%s\n' "${output}"
}

cleanup_retired_manifest_skill_links() {
  local target="$1"
  local dest_dir="$2"
  local active_links

  if ! declare -F state_list_tracked_symlinks_under >/dev/null; then
    return 0
  fi

  active_links="$(manifest_skill_links_for_cleanup "${target}")"
  [[ -n "${active_links//[[:space:]]/}" ]] || return 0

  local active_names=$'\n'
  local source_path skill
  while IFS=$'\t' read -r source_path skill; do
    [[ -n "${source_path}" && -n "${skill}" ]] || continue
    active_names+="${skill}"$'\n'
  done <<< "${active_links}"

  local tracked_path name display
  while IFS= read -r tracked_path; do
    [[ -n "${tracked_path}" ]] || continue
    name="$(basename "${tracked_path}")"
    [[ "${active_names}" == *$'\n'"${name}"$'\n'* ]] && continue
    display="${tracked_path/#${HOME}/~}"
    if [[ -L "${tracked_path}" ]]; then
      rm -f "${tracked_path}"
      yellow "  Removed retired VibeGuard skill link: ${display}"
    elif [[ -e "${tracked_path}" ]]; then
      yellow "  SKIP retired VibeGuard skill path is not a symlink: ${display}"
    fi
  done < <(state_list_tracked_symlinks_under "${dest_dir}")
}

install_manifest_skills() {
  local target_uri="$1" dest_dir="$2" install_fn="$3"
  local skill_links source_path skill

  mkdir -p "${dest_dir}"
  skill_links="$(manifest_skill_links_checked "${target_uri}")" || return 1
  while IFS=$'\t' read -r source_path skill; do
    [[ -n "${source_path}" && -n "${skill}" ]] || continue
    if [[ -d "${REPO_DIR}/${source_path}" ]]; then
      "${install_fn}" "${REPO_DIR}/${source_path}" "${dest_dir}/${skill}" "${source_path}" "${skill}" || return 1
    else
      yellow "  SKIP ${skill} (source not found: ${source_path})"
    fi
  done <<< "${skill_links}"
}

install_context_profiles() {
  local target_dir="$1" display_prefix="$2"
  mkdir -p "${target_dir}"
  local profile name
  for profile in "${REPO_DIR}"/context-profiles/*.md; do
    [[ -f "${profile}" ]] || continue
    name=$(basename "${profile}")
    cp "${profile}" "${target_dir}/${name}"
    state_record_file "${target_dir}/${name}" "context-profiles/${name}" "copy"
    green "  ${name} -> ${display_prefix}/${name}"
  done
}

vibeguard_rule_id_count() {
  local root="$1"
  local total=0 file_count rule_file
  if [[ ! -d "${root}" ]]; then
    printf '0\n'
    return 0
  fi
  while IFS= read -r rule_file; do
    file_count=$(grep -cE '^##[[:space:]]+(RS|GO|TS|PY|U|SEC|W|TASTE)-[A-Za-z0-9-]+([[:space:]:]|$)' "${rule_file}" 2>/dev/null || true)
    total=$((total + file_count))
  done < <(find "${root}" \( -type f -o -type l \) -name "*.md" 2>/dev/null)
  printf '%s\n' "${total}"
}

vibeguard_managed_rule_banner_count() {
  local file="$1"
  [[ -f "${file}" ]] || return 1
  awk '
    /<!-- vibeguard-start -->/ { in_block = 1; next }
    /<!-- vibeguard-end -->/ { in_block = 0 }
    in_block && match($0, /[0-9][0-9]* rules/) {
      text = substr($0, RSTART, RLENGTH)
      sub(/ rules$/, "", text)
      print text
      found = 1
      exit
    }
    END { if (!found) exit 1 }
  ' "${file}"
}

inject_vibeguard_rules() {
  local target_file="$1" display_label="$2" state_source="$3"
  local rules_file="${REPO_DIR}/claude-md/vibeguard-rules.md"
  local rules_diff rule_count result

  rule_count=$(claude_rule_count_for_banner)
  mkdir -p "$(dirname "${target_file}")"
  if ! rules_diff=$(python3 "${CLAUDE_MD_HELPER}" diff-inject "${target_file}" "${rules_file}" "${REPO_DIR}" "${rule_count}" 2>&1); then
    red "  Failed to compute ${display_label} diff"
    return 1
  fi
  if ! confirm_high_context_write "${display_label}" "${rules_diff}"; then
    if [[ "${VIBEGUARD_SETUP_DRY_RUN}" == "1" ]]; then
      echo
      return 0
    fi
    return 1
  fi
  if [[ "${rules_diff}" == "SKIP" ]]; then
    if [[ -f "${target_file}" ]]; then
      state_record_file "${target_file}" "${state_source}" "copy"
    fi
    green "  ${display_label} already up to date"
    echo
    return 0
  fi
  if result=$(python3 "${CLAUDE_MD_HELPER}" inject "${target_file}" "${rules_file}" "${REPO_DIR}" "${rule_count}" 2>&1); then
    if [[ -f "${target_file}" ]]; then
      state_record_file "${target_file}" "${state_source}" "copy"
    fi
    green "  VibeGuard rules synced to ${display_label} (${result})"
  else
    red "  Failed to update ${display_label}"
    return 1
  fi
  echo
}

confirm_high_context_write() {
  local label="$1"
  local diff_output="$2"

  if [[ "${diff_output}" == "SKIP" ]]; then
    return 0
  fi

  printf '%s\n' "${diff_output}" >&2

  if [[ "${VIBEGUARD_SETUP_DRY_RUN}" == "1" ]]; then
    yellow "  DRY-RUN: ${label} not written"
    return 1
  fi

  if [[ "${VIBEGUARD_SETUP_AUTO}" == "1" ]]; then
    yellow "  AUTO: applying ${label} (VIBEGUARD_SETUP_AUTO=1 or --yes)"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    red "  ERROR: ${label} requires explicit confirmation. Re-run with --yes or VIBEGUARD_SETUP_AUTO=1."
    return 2
  fi

  local answer
  read -r -p "Apply ${label}? [y/N] " answer
  case "${answer}" in
    y|Y|yes|YES) return 0 ;;
    *) red "  Aborted ${label}"; return 2 ;;
  esac
}

safe_symlink() {
  local src="$1" dst="$2"
  if [[ -d "${dst}" && ! -L "${dst}" ]]; then
    if [[ -n "$(ls -A "${dst}" 2>/dev/null)" ]]; then
      red "  ERROR: ${dst} is a non-empty directory, refusing to overwrite."
      red "  Please remove or rename it manually, then re-run setup.sh."
      return 1
    fi
    rmdir "${dst}"
  fi
  ln -sfn "${src}" "${dst}"
}

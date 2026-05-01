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

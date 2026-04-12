#!/usr/bin/env bash
# VibeGuard Setup — shared variables and functions
# Sourced by install.sh, check.sh, clean.sh

REPO_DIR="${VIBEGUARD_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
CLAUDE_DIR="${HOME}/.claude"
CODEX_DIR="${HOME}/.codex"
SETTINGS_HELPER="${REPO_DIR}/scripts/lib/settings_json.py"
CODEX_HOOKS_HELPER="${REPO_DIR}/scripts/lib/codex_hooks_json.py"
CLAUDE_MD_HELPER="${REPO_DIR}/scripts/lib/claude_md.py"
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"

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
  python3 "${SETTINGS_HELPER}" upsert-vibeguard --settings-file "${settings_file}" --repo-dir "${REPO_DIR}" --profile "${profile}"
}

settings_remove() {
  local settings_file="$1"
  python3 "${SETTINGS_HELPER}" remove-vibeguard --settings-file "${settings_file}"
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

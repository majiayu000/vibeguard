#!/usr/bin/env bash

GEMINI_DIR="${GEMINI_CLI_HOME:-${HOME}}/.gemini"
GEMINI_SETTINGS_FILE="${GEMINI_DIR}/settings.json"
GEMINI_WRAPPER="${HOME}/.vibeguard/run-hook-gemini.sh"
GEMINI_ENABLED_MARKER="${HOME}/.vibeguard/gemini-enabled"

gemini_install_expected() {
  [[ "${VIBEGUARD_SETUP_GEMINI:-0}" == "1" || -f "${GEMINI_ENABLED_MARKER}" ]]
}

configure_gemini_home_runtime() {
  gemini_install_expected || return 0
  echo "Step 6.7: Configure Gemini CLI hooks"

  local settings_diff result
  if ! settings_diff="$(
    setup_runtime setup-gemini-hooks-upsert \
      "${GEMINI_SETTINGS_FILE}" "${GEMINI_WRAPPER}" --dry-run 2>&1
  )"; then
    red "  Failed to compute ~/.gemini/settings.json diff"
    return 1
  fi
  if ! confirm_high_context_write "~/.gemini/settings.json" "${settings_diff}"; then
    if [[ "${VIBEGUARD_SETUP_DRY_RUN}" == "1" ]]; then
      echo
      return 0
    fi
    return 1
  fi

  mkdir -p "${GEMINI_DIR}" "${HOME}/.vibeguard"
  cp "${REPO_DIR}/hooks/run-hook-gemini.sh" "${GEMINI_WRAPPER}"
  chmod +x "${GEMINI_WRAPPER}"
  if ! result="$(
    setup_runtime setup-gemini-hooks-upsert \
      "${GEMINI_SETTINGS_FILE}" "${GEMINI_WRAPPER}" 2>&1
  )"; then
    red "  Failed to update ~/.gemini/settings.json"
    return 1
  fi
  printf 'gemini-cli-hooks-v1\n' > "${GEMINI_ENABLED_MARKER}"
  state_record_file "${GEMINI_WRAPPER}" "hooks/run-hook-gemini.sh" "copy"
  state_record_file "${GEMINI_SETTINGS_FILE}" "generated/gemini-settings.json" "copy"
  state_record_file "${GEMINI_ENABLED_MARKER}" "generated/gemini-enabled" "copy"
  green "  Gemini CLI adapter configured (${result})"
  echo
}

check_gemini_home_installation() {
  if ! gemini_install_expected; then
    yellow "[INFO] Gemini CLI adapter not enabled (opt in: bash setup.sh --yes --host gemini)"
    return 0
  fi
  if [[ ! -x "${GEMINI_WRAPPER}" ]]; then
    red "[BROKEN] Gemini CLI adapter wrapper missing: ${GEMINI_WRAPPER}"
    return 0
  fi
  if setup_runtime setup-gemini-hooks-check \
    "${GEMINI_SETTINGS_FILE}" "${GEMINI_WRAPPER}" >/dev/null 2>&1; then
    if ! command -v gemini >/dev/null 2>&1; then
      yellow "[WARN] Gemini CLI adapter configured, but the gemini executable is not available"
    elif ! gemini hooks --help >/dev/null 2>&1; then
      red "[BROKEN] Gemini CLI does not expose hook support; upgrade Gemini CLI"
    else
      green "[OK] Gemini CLI BeforeTool adapter active"
    fi
  else
    red "[BROKEN] Gemini CLI adapter is not canonical in ~/.gemini/settings.json"
  fi
}

gemini_semantic_drift_message() {
  local path="$1"
  [[ "${path}" == "${GEMINI_SETTINGS_FILE}" ]] || return 1
  if [[ -f "${GEMINI_SETTINGS_FILE}" ]] \
    && setup_runtime setup-gemini-hooks-check \
      "${GEMINI_SETTINGS_FILE}" "${GEMINI_WRAPPER}" >/dev/null 2>&1; then
    printf '%s\n' "${path} (checksum drift; VibeGuard Gemini hook semantics OK)"
    return 0
  fi
  return 1
}

clean_gemini_home_installation() {
  local result
  if [[ ! -f "${GEMINI_ENABLED_MARKER}" && ! -e "${GEMINI_WRAPPER}" ]]; then
    return 0
  fi
  if ! result="$(
    setup_runtime setup-gemini-hooks-remove "${GEMINI_SETTINGS_FILE}" 2>&1
  )"; then
    red "Failed to clean VibeGuard entries in ~/.gemini/settings.json"
    return 1
  fi
  case "${result}" in
    CHANGED) yellow "Removed VibeGuard hook entry from ~/.gemini/settings.json" ;;
    SKIP) yellow "No VibeGuard hook entry found in ~/.gemini/settings.json" ;;
    *) red "Unexpected Gemini clean result: ${result}"; return 1 ;;
  esac
  rm -f "${GEMINI_WRAPPER}" "${GEMINI_ENABLED_MARKER}"
}

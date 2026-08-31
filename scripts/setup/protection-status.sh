#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=../lib/install-state.sh
source "${SCRIPT_DIR}/../lib/install-state.sh"
# shellcheck source=targets/claude-home.sh
source "${SCRIPT_DIR}/targets/claude-home.sh"
# shellcheck source=targets/codex-home.sh
source "${SCRIPT_DIR}/targets/codex-home.sh"
# shellcheck source=targets/gemini-home.sh
source "${SCRIPT_DIR}/targets/gemini-home.sh"

usage() {
  cat <<'USAGE'
Usage: bash setup.sh protection-status [project_root]

Report whether each supported host has canonical configuration and a real
VibeGuard hook event for the selected Git project. This command is read-only.
USAGE
}

case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
esac
if [[ $# -gt 1 ]]; then
  printf 'ERROR: protection-status accepts at most one project_root\n' >&2
  exit 64
fi

target_dir="${1:-${PWD}}"
if [[ ! -d "${target_dir}" ]]; then
  printf 'ERROR: project directory does not exist: %s\n' "${target_dir}" >&2
  exit 2
fi
if ! project_root="$(git -C "${target_dir}" rev-parse --show-toplevel 2>/dev/null)" \
  || [[ -z "${project_root}" ]]; then
  printf 'ERROR: protection-status requires a Git project: %s\n' "${target_dir}" >&2
  exit 2
fi
project_root="$(cd "${project_root}" && pwd -P)"

if ! runtime="$(setup_runtime_path)"; then
  printf 'ERROR: vibeguard-runtime is unavailable; run: bash setup.sh --yes\n' >&2
  exit 2
fi
if ! profile="$(state_installed_profile)"; then
  printf 'ERROR: cannot determine the installed VibeGuard profile\n' >&2
  exit 2
fi
export PROFILE="${profile}"

find_project_event_file() {
  local log_root="${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}"
  local marker mapped_root mapped_root_abs
  local -a markers=()
  shopt -s nullglob
  markers=("${log_root}"/projects/*/.project-root)
  shopt -u nullglob
  for marker in "${markers[@]}"; do
    if [[ ! -r "${marker}" ]]; then
      printf 'ERROR: project log marker is unreadable: %s\n' "${marker}" >&2
      return 2
    fi
    mapped_root="$(<"${marker}")"
    [[ -n "${mapped_root}" && -d "${mapped_root}" ]] || continue
    mapped_root_abs="$(cd "${mapped_root}" && pwd -P)"
    if [[ "${mapped_root_abs}" == "${project_root}" ]]; then
      printf '%s\n' "${marker%/.project-root}/events.jsonl"
      return 0
    fi
  done
  return 1
}

latest_event_for() {
  local host="$1"
  awk -F '\t' -v host="${host}" '$1 == host { print $2 "\t" $3 "\t" $4; exit }' \
    <<< "${event_summary}"
}

event_file=""
event_file_status=0
event_file="$(find_project_event_file)" || event_file_status=$?
if [[ "${event_file_status}" -eq 2 ]]; then
  exit 2
fi

event_summary=""
if [[ -n "${event_file}" && -e "${event_file}" ]]; then
  if [[ ! -r "${event_file}" ]]; then
    printf 'ERROR: project event log is unreadable: %s\n' "${event_file}" >&2
    exit 2
  fi
  if ! event_summary="$("${runtime}" latest-client-events < "${event_file}")"; then
    printf 'ERROR: failed to read project event evidence: %s\n' "${event_file}" >&2
    exit 2
  fi
fi

claude_event="$(latest_event_for claude)"
codex_event="$(latest_event_for codex)"
gemini_event="$(latest_event_for gemini)"

claude_enabled=0
claude_configured=0
claude_settings_canonical=0
if settings_check "${SETTINGS_FILE}" "profile-hooks:${profile}"; then
  claude_settings_canonical=1
fi
if [[ -e "${HOME}/.vibeguard/run-hook.sh" ]] \
  || { [[ -f "${SETTINGS_FILE}" ]] && grep -Fq 'run-hook.sh' "${SETTINGS_FILE}"; }; then
  claude_enabled=1
fi
if [[ -x "${HOME}/.vibeguard/run-hook.sh" ]] \
  && [[ -f "$(_claude_source_path "hooks/pre-bash-guard.sh")" ]] \
  && [[ "${claude_settings_canonical}" -eq 1 ]]; then
  claude_configured=1
fi

codex_enabled=0
codex_configured=0
codex_hooks_file="${CODEX_DIR}/hooks.json"
codex_wrapper="${HOME}/.vibeguard/run-hook-codex.sh"
codex_config="${CODEX_DIR}/config.toml"
if [[ -e "${codex_wrapper}" ]] \
  || { [[ -f "${codex_hooks_file}" ]] && grep -Fq 'run-hook-codex.sh' "${codex_hooks_file}"; }; then
  codex_enabled=1
fi
codex_feature_status=""
if [[ -f "${codex_config}" ]]; then
  codex_feature_status="$("${runtime}" setup-codex-config-check-hooks "${codex_config}" 2>/dev/null || true)"
fi
if [[ -x "${codex_wrapper}" ]] \
  && [[ -f "$(_codex_source_path "hooks/pre-bash-guard.sh")" ]] \
  && [[ "${codex_feature_status}" == "OK" ]] \
  && "${runtime}" setup-codex-hooks-check \
    "${REPO_DIR}" "${codex_hooks_file}" "${codex_wrapper}" "${profile}" >/dev/null 2>&1; then
  codex_configured=1
fi

gemini_enabled=0
gemini_configured=0
if gemini_install_expected; then
  gemini_enabled=1
fi
if [[ "${gemini_enabled}" -eq 1 ]] \
  && [[ -x "${GEMINI_WRAPPER}" ]] \
  && [[ -x "${HOME}/.vibeguard/run-hook.sh" ]] \
  && [[ -f "$(_claude_source_path "hooks/pre-bash-guard.sh")" ]] \
  && "${runtime}" setup-gemini-hooks-check \
    "${GEMINI_SETTINGS_FILE}" "${GEMINI_WRAPPER}" >/dev/null 2>&1 \
  && command -v gemini >/dev/null 2>&1 \
  && gemini hooks --help >/dev/null 2>&1; then
  gemini_configured=1
fi

render_host() {
  local label="$1" enabled="$2" configured="$3" event="$4" install_command="$5"
  local ts hook decision
  if [[ "${enabled}" -eq 0 ]]; then
    printf '%s: UNPROTECTED\n' "${label}"
    printf '  Reason: Integration is not enabled.\n'
    printf '  Next: %s\n' "${install_command}"
    return
  fi
  if [[ "${configured}" -eq 0 ]]; then
    printf '%s: DEGRADED\n' "${label}"
    printf '  Reason: The installed integration is incomplete or non-canonical.\n'
    printf '  Next: %s\n' "${install_command}"
    return
  fi
  if [[ -z "${event}" ]]; then
    printf '%s: DEGRADED\n' "${label}"
    printf '  Reason: No %s hook event has been observed for this project.\n' "${label}"
    printf '  Next: Start %s in this project, run a safe command, then rerun protection-status.\n' "${label}"
    return
  fi
  IFS=$'\t' read -r ts hook decision <<< "${event}"
  printf '%s: PROTECTED\n' "${label}"
  printf '  Evidence: canonical %s configuration; latest project event %s | %s | %s\n' \
    "${profile}" "${ts}" "${hook}" "${decision}"
}

printf '%s\n' 'VibeGuard Protection Status'
printf 'Project: %s\n\n' "${project_root}"
render_host "Claude Code" "${claude_enabled}" "${claude_configured}" "${claude_event}" \
  "bash setup.sh --yes --profile ${profile}"
printf '\n'
render_host "Codex CLI" "${codex_enabled}" "${codex_configured}" "${codex_event}" \
  "bash setup.sh --yes --profile ${profile}"
printf '\n'
render_host "Gemini CLI" "${gemini_enabled}" "${gemini_configured}" "${gemini_event}" \
  "bash setup.sh --yes --host gemini"

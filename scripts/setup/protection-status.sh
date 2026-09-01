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
# shellcheck source=../lib/log_scope.sh
source "${SCRIPT_DIR}/../lib/log_scope.sh"

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

installed_runtime="${HOME}/.vibeguard/installed/bin/vibeguard-runtime"
installed_runtime_problem=""
if [[ ! -x "${installed_runtime}" ]]; then
  installed_runtime_problem="Required installed runtime is missing or not executable: ${installed_runtime}"
elif ! setup_runtime_supports "${installed_runtime}"; then
  installed_runtime_problem="Required installed runtime is incompatible or corrupt: ${installed_runtime}"
fi

resolve_effective_profile() {
  local output status=0 effective_profile
  output="$(
    "${runtime}" runtime-policy-check --cwd "${project_root}" pre-bash-guard.sh 2>/dev/null
  )" || status=$?
  case "${status}" in
    0|10) ;;
    *) return 1 ;;
  esac
  effective_profile="$(
    printf '%s' "${output}" | "${runtime}" json-field --strict profile 2>/dev/null
  )" || return 1
  [[ -n "${effective_profile}" && "${effective_profile}" != "null" ]] || return 1
  printf '%s\n' "${effective_profile}"
}

if ! effective_profile="$(resolve_effective_profile)"; then
  printf 'ERROR: failed to resolve the project profile: %s\n' "${project_root}" >&2
  exit 2
fi

resolve_project_event_file() {
  local log_root="${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}"
  vg_log_scope_project_log_file "${log_root}" "${project_root}"
}

latest_event_for() {
  local host="$1"
  awk -F '\t' -v host="${host}" '$1 == host { print $2 "\t" $3 "\t" $4; exit }' \
    <<< "${event_summary}"
}

event_file=""
if ! event_file="$(resolve_project_event_file)"; then
  printf 'ERROR: failed to resolve project event log: %s\n' "${project_root}" >&2
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

if ! installed_claude_profile_hooks="$(
  "${runtime}" setup-claude-profile-hook-scripts "${REPO_DIR}" "${profile}"
)" || [[ -z "${installed_claude_profile_hooks}" ]]; then
  printf 'ERROR: failed to resolve Claude hook assets for profile %s\n' "${profile}" >&2
  exit 2
fi
if ! installed_codex_profile_hooks="$(
  "${runtime}" setup-codex-profile-hook-scripts "${REPO_DIR}" "${profile}"
)" || [[ -z "${installed_codex_profile_hooks}" ]]; then
  printf 'ERROR: failed to resolve Codex hook assets for profile %s\n' "${profile}" >&2
  exit 2
fi
if ! codex_profile_hooks="$(
  "${runtime}" setup-codex-profile-hook-scripts "${REPO_DIR}" "${effective_profile}"
)" || [[ -z "${codex_profile_hooks}" ]]; then
  printf 'ERROR: failed to resolve Codex hook assets for profile %s\n' "${effective_profile}" >&2
  exit 2
fi
if ! claude_profile_hooks="$(
  "${runtime}" setup-claude-profile-hook-scripts "${REPO_DIR}" "${effective_profile}"
)" || [[ -z "${claude_profile_hooks}" ]]; then
  printf 'ERROR: failed to resolve Claude hook assets for profile %s\n' "${effective_profile}" >&2
  exit 2
fi
gemini_profile_hooks=$'pre-bash-guard.sh\npre-edit-guard.sh\npre-write-guard.sh'

profile_hook_problem() {
  local host="$1" effective_hooks="$2" installed_hooks hook
  case "${host}" in
    claude) installed_hooks="${installed_claude_profile_hooks}" ;;
    codex) installed_hooks="${installed_codex_profile_hooks}" ;;
    *) return 0 ;;
  esac
  while IFS= read -r hook; do
    [[ -n "${hook}" ]] || continue
    if ! grep -Fqx "${hook}" <<< "${installed_hooks}"; then
      printf 'Project profile %s requires %s for %s, but installed profile %s does not configure it.' \
        "${effective_profile}" "${hook}" "${host}" "${profile}"
      return 10
    fi
  done <<< "${effective_hooks}"
  return 0
}

canonical_asset_problem() {
  local actual="$1" canonical="$2" label="$3"
  if [[ ! -f "${actual}" ]]; then
    printf 'Required %s is missing: %s' "${label}" "${actual}"
    return 10
  fi
  if ! cmp -s "${canonical}" "${actual}"; then
    printf 'Required %s has drifted: %s' "${label}" "${actual}"
    return 10
  fi
  return 0
}

hook_assets_problem() {
  local host="$1" hooks="$2" wrapper="$3" hook source_path canonical_path
  canonical_asset_problem \
    "${HOME}/.vibeguard/${wrapper}" "${REPO_DIR}/hooks/${wrapper}" "hook wrapper" || return $?
  if [[ "${host}" == "gemini" ]]; then
    canonical_asset_problem \
      "${HOME}/.vibeguard/run-hook.sh" "${REPO_DIR}/hooks/run-hook.sh" \
      "shared hook wrapper" || return $?
  fi
  while IFS= read -r hook; do
    [[ -n "${hook}" ]] || continue
    case "${host}" in
      codex) source_path="$(_codex_source_path "hooks/${hook}")" ;;
      *) source_path="$(_claude_source_path "hooks/${hook}")" ;;
    esac
    canonical_asset_problem \
      "${source_path}" "${REPO_DIR}/hooks/${hook}" "hook asset" || return $?
  done <<< "${hooks}"
  while IFS= read -r canonical_path; do
    [[ -n "${canonical_path}" ]] || continue
    hook="${canonical_path#"${REPO_DIR}/hooks/"}"
    case "${host}" in
      codex) source_path="$(_codex_source_path "hooks/${hook}")" ;;
      *) source_path="$(_claude_source_path "hooks/${hook}")" ;;
    esac
    canonical_asset_problem "${source_path}" "${canonical_path}" "hook helper" || return $?
  done < <(find "${REPO_DIR}/hooks/_lib" -type f -name '*.sh' -print)
  return 0
}

hook_policy_problem() {
  local hook="$1" output status=0 enforcement user_config
  user_config="${VIBEGUARD_CONFIG_FILE:-${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}/config.json}"
  output="$(
    VG_INTERNAL_USER_CONFIG_FILE="${user_config}" \
    VIBEGUARD_USER_CONFIG_FILE="${user_config}" \
      "${runtime}" runtime-policy-check --cwd "${project_root}" "${hook}" 2>/dev/null
  )" || status=$?
  case "${status}" in
    0)
      if ! enforcement="$(
        printf '%s' "${output}" | "${runtime}" json-field --strict enforcement 2>/dev/null
      )"; then
        printf 'ERROR: runtime policy returned invalid evidence for %s\n' "${hook}" >&2
        return 2
      fi
      if [[ "${enforcement}" != "block" ]]; then
        printf 'Project policy weakens %s to %s enforcement.' "${hook}" "${enforcement:-unknown}"
        return 10
      fi
      ;;
    10)
      printf 'Project policy disables %s.' "${hook}"
      return 10
      ;;
    *)
      printf 'ERROR: failed to evaluate project policy for %s\n' "${hook}" >&2
      return 2
      ;;
  esac
  return 0
}

hook_set_policy_problem() {
  local hooks="$1" hook result status
  while IFS= read -r hook; do
    [[ -n "${hook}" ]] || continue
    result=""
    status=0
    result="$(hook_policy_problem "${hook}")" || status=$?
    case "${status}" in
      0) ;;
      10) printf '%s' "${result}"; return 10 ;;
      *) return 2 ;;
    esac
  done <<< "${hooks}"
  return 0
}

host_problem() {
  local host="$1" hooks="$2" wrapper="$3" result status=0
  if [[ -n "${installed_runtime_problem}" ]]; then
    printf '%s' "${installed_runtime_problem}"
    return 0
  fi
  result="$(profile_hook_problem "${host}" "${hooks}")" || status=$?
  case "${status}" in
    0) ;;
    10) printf '%s' "${result}"; return 0 ;;
    *) return 2 ;;
  esac
  status=0
  result="$(hook_assets_problem "${host}" "${hooks}" "${wrapper}")" || status=$?
  case "${status}" in
    0) ;;
    10) printf '%s' "${result}"; return 0 ;;
    *) return 2 ;;
  esac
  status=0
  result="$(hook_set_policy_problem "${hooks}")" || status=$?
  case "${status}" in
    0) return 0 ;;
    10) printf '%s' "${result}"; return 0 ;;
    *) return 2 ;;
  esac
}

if ! claude_problem="$(host_problem claude "${claude_profile_hooks}" run-hook.sh)" \
  || ! codex_problem="$(host_problem codex "${codex_profile_hooks}" run-hook-codex.sh)" \
  || ! gemini_problem="$(host_problem gemini "${gemini_profile_hooks}" run-hook-gemini.sh)"; then
  exit 2
fi

claude_enabled=0
claude_configured=0
claude_settings_canonical=0
if settings_check "${SETTINGS_FILE}" "canonical-profile-hooks:${profile}"; then
  claude_settings_canonical=1
fi
if [[ -e "${HOME}/.vibeguard/run-hook.sh" ]] \
  || { [[ -f "${SETTINGS_FILE}" ]] && grep -Fq 'run-hook.sh' "${SETTINGS_FILE}"; }; then
  claude_enabled=1
fi
if [[ -x "${HOME}/.vibeguard/run-hook.sh" ]] \
  && [[ -f "$(_claude_source_path "hooks/pre-bash-guard.sh")" ]] \
  && [[ "${claude_settings_canonical}" -eq 1 ]] \
  && [[ -z "${claude_problem}" ]]; then
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
    "${REPO_DIR}" "${codex_hooks_file}" "${codex_wrapper}" "${profile}" >/dev/null 2>&1 \
  && [[ -z "${codex_problem}" ]]; then
  codex_configured=1
fi

gemini_enabled=0
gemini_configured=0
if gemini_install_expected \
  || [[ -e "${GEMINI_WRAPPER}" ]] \
  || { [[ -f "${GEMINI_SETTINGS_FILE}" ]] \
    && grep -Fq 'run-hook-gemini.sh' "${GEMINI_SETTINGS_FILE}"; }; then
  gemini_enabled=1
fi
if [[ "${gemini_enabled}" -eq 1 ]] \
  && [[ -f "${GEMINI_ENABLED_MARKER}" ]] \
  && [[ -x "${GEMINI_WRAPPER}" ]] \
  && [[ -x "${HOME}/.vibeguard/run-hook.sh" ]] \
  && [[ -f "$(_claude_source_path "hooks/pre-bash-guard.sh")" ]] \
  && "${runtime}" setup-gemini-hooks-check \
    "${GEMINI_SETTINGS_FILE}" "${GEMINI_WRAPPER}" >/dev/null 2>&1 \
  && command -v gemini >/dev/null 2>&1 \
  && gemini hooks --help >/dev/null 2>&1 \
  && [[ -z "${gemini_problem}" ]]; then
  gemini_configured=1
fi

render_host() {
  local label="$1" enabled="$2" configured="$3" event="$4" install_command="$5" problem="$6"
  local ts hook decision
  if [[ "${enabled}" -eq 0 ]]; then
    printf '%s: UNPROTECTED\n' "${label}"
    printf '  Reason: Integration is not enabled.\n'
    printf '  Next: %s\n' "${install_command}"
    return
  fi
  if [[ "${configured}" -eq 0 ]]; then
    printf '%s: DEGRADED\n' "${label}"
    printf '  Reason: %s\n' "${problem:-The installed integration is incomplete or non-canonical.}"
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
setup_entrypoint="$(printf '%q' "${REPO_DIR}/setup.sh")"
render_host "Claude Code" "${claude_enabled}" "${claude_configured}" "${claude_event}" \
  "bash ${setup_entrypoint} --yes --profile ${profile}" "${claude_problem}"
printf '\n'
render_host "Codex CLI" "${codex_enabled}" "${codex_configured}" "${codex_event}" \
  "bash ${setup_entrypoint} --yes --profile ${profile}" "${codex_problem}"
printf '\n'
render_host "Gemini CLI" "${gemini_enabled}" "${gemini_configured}" "${gemini_event}" \
  "bash ${setup_entrypoint} --yes --host gemini --profile ${profile}" "${gemini_problem}"

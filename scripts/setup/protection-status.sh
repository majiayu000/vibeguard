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
effective_policy_cwd="${VIBEGUARD_POLICY_CWD:-${VIBEGUARD_PROJECT_ROOT:-${VIBEGUARD_PROJECT_CWD:-${project_root}}}}"

if ! runtime="$(setup_runtime_path)"; then
  printf 'ERROR: vibeguard-runtime is unavailable; run: bash setup.sh --yes\n' >&2
  exit 2
fi
if ! profile="$(state_installed_profile)"; then
  printf 'ERROR: cannot determine the installed VibeGuard profile\n' >&2
  exit 2
fi
export PROFILE="${profile}"

execution_mode="${VIBEGUARD_EXECUTION_MODE:-}"
if [[ -z "${execution_mode}" && -f "${HOME}/.vibeguard/execution-mode" ]]; then
  execution_mode="$(tr -d '[:space:]' < "${HOME}/.vibeguard/execution-mode")"
fi
case "${execution_mode}" in
  dev-linked|dev-linked-repo|repo|repo-linked)
    execution_mode="dev-linked-repo"
    ;;
  *)
    execution_mode="installed-snapshot"
    ;;
esac
execution_root="${HOME}/.vibeguard/installed"
execution_problem=""
if [[ "${execution_mode}" == "dev-linked-repo" ]]; then
  repo_path_file="${HOME}/.vibeguard/repo-path"
  live_repo=""
  if [[ ! -r "${repo_path_file}" ]]; then
    execution_problem="Dev-linked execution requires a readable repo-path: ${repo_path_file}"
  elif ! live_repo="$(<"${repo_path_file}")" || [[ -z "${live_repo}" ]]; then
    execution_problem="Dev-linked execution has an unreadable or empty repo-path: ${repo_path_file}"
  elif ! live_repo_root="$(git -C "${live_repo}" rev-parse --show-toplevel 2>/dev/null)" \
    || [[ -z "${live_repo_root}" ]]; then
    execution_problem="Dev-linked repo-path is not a Git repository: ${live_repo}"
  else
    live_repo="$(cd "${live_repo}" && pwd -P)"
    live_repo_root="$(cd "${live_repo_root}" && pwd -P)"
    if [[ "${live_repo}" != "${live_repo_root}" ]]; then
      execution_problem="Dev-linked repo-path is not the repository root: ${live_repo}"
    else
      execution_root="${live_repo_root}"
    fi
  fi
fi

installed_runtime="${HOME}/.vibeguard/installed/bin/vibeguard-runtime"
installed_runtime_problem=""
if [[ ! -x "${installed_runtime}" ]]; then
  installed_runtime_problem="Required installed runtime is missing or not executable: ${installed_runtime}"
elif ! setup_runtime_supports "${installed_runtime}"; then
  installed_runtime_problem="Required installed runtime is incompatible or corrupt: ${installed_runtime}"
fi

runtime_override_problem=""
runtime_override="${VIBEGUARD_RUNTIME:-}"
if [[ -n "${runtime_override}" && -f "${runtime_override}" && -x "${runtime_override}" ]] \
  && ! setup_runtime_supports "${runtime_override}"; then
  runtime_override_problem="Selected runtime override VIBEGUARD_RUNTIME is incompatible or corrupt: ${runtime_override}"
fi

policy_runtime_override_problem=""
policy_runtime_override="${VIBEGUARD_POLICY_RUNTIME:-}"
policy_runtime_handshake=""
if [[ -n "${policy_runtime_override}" \
  && -f "${policy_runtime_override}" \
  && -x "${policy_runtime_override}" ]] \
  && policy_runtime_handshake="$(
    "${policy_runtime_override}" runtime-policy-supports 2>/dev/null
  )" \
  && [[ "${policy_runtime_handshake}" == "vibeguard-runtime-policy-v1" ]] \
  && ! setup_runtime_supports "${policy_runtime_override}"; then
  policy_runtime_override_problem="Selected policy runtime override VIBEGUARD_POLICY_RUNTIME is incompatible or corrupt: ${policy_runtime_override}"
fi

dev_linked_runtime_problem=""
if [[ "${execution_mode}" == "dev-linked-repo" && -z "${execution_problem}" ]]; then
  linked_runtime=""
  for candidate in \
    "${VIBEGUARD_RUNTIME:-}" \
    "${execution_root}/vibeguard-runtime/target/release/vibeguard-runtime" \
    "${execution_root}/vibeguard-runtime/target/debug/vibeguard-runtime" \
    "${installed_runtime}" \
    "${execution_root}/hooks/vibeguard-runtime"; do
    if [[ -n "${candidate}" && -f "${candidate}" && -x "${candidate}" ]]; then
      linked_runtime="${candidate}"
      break
    fi
  done
  if [[ -z "${linked_runtime}" ]]; then
    dev_linked_runtime_problem="Required dev-linked runtime is missing."
  elif ! setup_runtime_supports "${linked_runtime}"; then
    dev_linked_runtime_problem="Required dev-linked runtime is incompatible or corrupt: ${linked_runtime}"
  fi
fi

hook_dir_override_problem=""
if [[ -n "${VIBEGUARD_HOOK_DIR:-}" ]]; then
  expected_hook_dir="${execution_root}/hooks"
  selected_hook_dir="${VIBEGUARD_HOOK_DIR}"
  if [[ ! -d "${selected_hook_dir}" ]]; then
    hook_dir_override_problem="Selected hook directory override VIBEGUARD_HOOK_DIR is missing or not a directory: ${selected_hook_dir}"
  elif [[ -d "${expected_hook_dir}" ]]; then
    selected_hook_dir="$(cd "${selected_hook_dir}" && pwd -P)"
    expected_hook_dir="$(cd "${expected_hook_dir}" && pwd -P)"
    if [[ "${selected_hook_dir}" != "${expected_hook_dir}" ]]; then
      hook_dir_override_problem="Selected hook directory override VIBEGUARD_HOOK_DIR does not match the active hook directory: ${selected_hook_dir}"
    fi
  fi
fi

active_root_override_problem=""
installed_root_override_problem=""
if [[ -n "${VIBEGUARD_DIR:-}" ]]; then
  selected_vibeguard_dir="${VIBEGUARD_DIR}"
  if [[ ! -d "${selected_vibeguard_dir}" ]]; then
    active_root_override_problem="Selected VibeGuard root override VIBEGUARD_DIR is missing or not a directory: ${selected_vibeguard_dir}"
    installed_root_override_problem="${active_root_override_problem}"
  else
    selected_vibeguard_dir="$(cd "${selected_vibeguard_dir}" && pwd -P)"
    active_execution_root="$(cd "${execution_root}" && pwd -P)"
    installed_execution_root="$(cd "${HOME}/.vibeguard/installed" && pwd -P)"
    if [[ "${selected_vibeguard_dir}" != "${active_execution_root}" ]]; then
      active_root_override_problem="Selected VibeGuard root override VIBEGUARD_DIR does not match the active execution root: ${selected_vibeguard_dir}"
    fi
    if [[ "${selected_vibeguard_dir}" != "${installed_execution_root}" ]]; then
      installed_root_override_problem="Selected VibeGuard root override VIBEGUARD_DIR does not match the installed execution root: ${selected_vibeguard_dir}"
    fi
  fi
fi

precommit_skip_problem=""
if [[ "${VIBEGUARD_SKIP_PRECOMMIT:-0}" == "1" ]]; then
  precommit_skip_problem="Pre-commit enforcement is disabled by VIBEGUARD_SKIP_PRECOMMIT=1."
fi

precommit_timeout_problem=""
if [[ "${VIBEGUARD_PRECOMMIT_TIMEOUT_BEHAVIOR:-block}" == "warn" ]]; then
  precommit_timeout_problem="Pre-commit timeout enforcement is downgraded by VIBEGUARD_PRECOMMIT_TIMEOUT_BEHAVIOR=warn."
fi

resolve_effective_profile() {
  local policy_cwd="$1" output status=0 effective_profile
  output="$(
    "${runtime}" runtime-policy-check --cwd "${policy_cwd}" pre-bash-guard.sh 2>/dev/null
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

if ! effective_profile="$(resolve_effective_profile "${effective_policy_cwd}")"; then
  printf 'ERROR: failed to resolve the project profile: %s\n' "${effective_policy_cwd}" >&2
  exit 2
fi

resolve_project_event_file() {
  local log_root="$1"
  vg_log_scope_project_log_file "${log_root}" "${project_root}"
}

latest_event_for() {
  local host="$1" summary="$2"
  awk -F '\t' -v host="${host}" '$1 == host { print $2 "\t" $3 "\t" $4; exit }' \
    <<< "${summary}"
}

event_summary_for_file() {
  local event_file="$1" summary=""
  if [[ -n "${event_file}" && -e "${event_file}" ]]; then
    if [[ ! -r "${event_file}" ]]; then
      printf 'ERROR: project event log is unreadable: %s\n' "${event_file}" >&2
      return 2
    fi
    if ! summary="$("${runtime}" latest-client-events < "${event_file}")"; then
      printf 'ERROR: failed to read project event evidence: %s\n' "${event_file}" >&2
      return 2
    fi
  fi
  printf '%s' "${summary}"
}

event_summary_for_log_root() {
  local log_root="$1" event_file
  if ! event_file="$(resolve_project_event_file "${log_root}")"; then
    printf 'ERROR: failed to resolve project event log: %s\n' "${project_root}" >&2
    return 2
  fi
  event_summary_for_file "${event_file}"
}

validate_explicit_project_log() {
  local log_dir="$1" log_file="$2"
  local canonical_log_dir canonical_file_dir mapping mapped_root project_id
  if [[ ! -d "${log_dir}" ]] \
    || ! canonical_log_dir="$(cd "${log_dir}" && pwd -P)" \
    || ! canonical_file_dir="$(cd "$(dirname "${log_file}")" && pwd -P)"; then
    printf 'ERROR: explicit project log is not associated with the requested project: %s\n' \
      "${log_dir}" >&2
    return 1
  fi
  if [[ "${canonical_file_dir}" != "${canonical_log_dir}" ]]; then
    printf 'ERROR: explicit project log is not associated with the requested project: %s\n' \
      "${log_file}" >&2
    return 1
  fi
  if [[ -L "${log_file}" ]]; then
    printf 'ERROR: explicit project log is not associated with the requested project: %s\n' \
      "${log_file}" >&2
    return 1
  fi

  mapping="${canonical_log_dir}/.project-root"
  if [[ -e "${mapping}" ]]; then
    if ! mapped_root="$(<"${mapping}")" || [[ "${mapped_root}" != "${project_root}" ]]; then
      printf 'ERROR: explicit project log is not associated with the requested project: %s\n' \
        "${log_dir}" >&2
      return 1
    fi
    return 0
  fi

  project_id="$(vg_log_scope_sha256_short "${project_root}")" || return 1
  if [[ "${canonical_log_dir##*/}" != "${project_id}" ]]; then
    printf 'ERROR: explicit project log is not associated with the requested project: %s\n' \
      "${log_dir}" >&2
    return 1
  fi
}

primary_log_root="${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}"
primary_uses_explicit_log=0
if [[ -n "${VIBEGUARD_PROJECT_LOG_DIR:-}" && -n "${VIBEGUARD_LOG_FILE:-}" ]]; then
  primary_uses_explicit_log=1
  validate_explicit_project_log \
    "${VIBEGUARD_PROJECT_LOG_DIR}" "${VIBEGUARD_LOG_FILE}" || exit 2
  event_summary="$(event_summary_for_file "${VIBEGUARD_LOG_FILE}")" || exit 2
elif ! event_summary="$(event_summary_for_log_root "${primary_log_root}")"; then
  exit 2
fi
gemini_log_root="${HOME}/.vibeguard"
if [[ "${primary_uses_explicit_log}" -eq 1 \
  || "${gemini_log_root}" == "${primary_log_root}" ]]; then
  gemini_event_summary="${event_summary}"
elif ! gemini_event_summary="$(event_summary_for_log_root "${gemini_log_root}")"; then
  exit 2
fi

claude_event="$(latest_event_for claude "${event_summary}")"
codex_event="$(latest_event_for codex "${event_summary}")"
gemini_event="$(latest_event_for gemini "${gemini_event_summary}")"

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

hook_set_covers() {
  local installed_hooks="$1" effective_hooks="$2" hook
  while IFS= read -r hook; do
    [[ -n "${hook}" ]] || continue
    grep -Fqx "${hook}" <<< "${installed_hooks}" || return 1
  done <<< "${effective_hooks}"
  return 0
}

repair_profile="${profile}"
if ! hook_set_covers "${installed_claude_profile_hooks}" "${claude_profile_hooks}" \
  || ! hook_set_covers "${installed_codex_profile_hooks}" "${codex_profile_hooks}"; then
  repair_profile="${effective_profile}"
fi

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
  local host="$1" hooks="$2" wrapper="$3" hook source_path canonical_path source_root
  local active_sources="" dependency_sources="" required_assets="" relative_path candidate_base
  local changed referenced guard_source guard_dir guard_candidate
  if [[ "${host}" == "gemini" ]]; then
    source_root="${HOME}/.vibeguard/installed"
  else
    source_root="${execution_root}"
  fi
  canonical_asset_problem \
    "${HOME}/.vibeguard/${wrapper}" "${REPO_DIR}/hooks/${wrapper}" "hook wrapper" || return $?
  if [[ "${host}" == "codex" && -n "${VIBEGUARD_CODEX_ADAPTER_PATH:-}" ]]; then
    canonical_asset_problem \
      "${VIBEGUARD_CODEX_ADAPTER_PATH}" "${REPO_DIR}/hooks/_lib/codex_adapter.sh" \
      "Codex adapter override" || return $?
  fi
  if [[ "${host}" == "gemini" ]]; then
    canonical_asset_problem \
      "${HOME}/.vibeguard/run-hook.sh" "${REPO_DIR}/hooks/run-hook.sh" \
      "shared hook wrapper" || return $?
    dependency_sources+=$'\n'"${REPO_DIR}/hooks/run-hook.sh"
  fi
  dependency_sources="${REPO_DIR}/hooks/${wrapper}${dependency_sources}"
  while IFS= read -r hook; do
    [[ -n "${hook}" ]] || continue
    relative_path="hooks/${hook}"
    [[ -z "${required_assets}" ]] || required_assets+=$'\n'
    required_assets+="${relative_path}"
    [[ -z "${active_sources}" ]] || active_sources+=$'\n'
    active_sources+="${REPO_DIR}/${relative_path}"
    dependency_sources+=$'\n'"${REPO_DIR}/${relative_path}"
  done <<< "${hooks}"

  # Top-level libraries are dependencies only when an active profile hook
  # sources them. Manual and otherwise unconfigured hook scripts are ignored.
  while IFS= read -r canonical_path; do
    [[ -n "${canonical_path}" ]] || continue
    relative_path="hooks/${canonical_path#"${REPO_DIR}/hooks/"}"
    grep -Fqx "${relative_path}" <<< "${required_assets}" && continue
    candidate_base="${canonical_path##*/}"
    referenced=0
    while IFS= read -r source_path; do
      [[ -n "${source_path}" ]] || continue
      if grep -Fq "/${candidate_base}" "${source_path}"; then
        referenced=1
        break
      fi
    done <<< "${active_sources}"
    [[ "${referenced}" -eq 1 ]] || continue
    [[ -z "${required_assets}" ]] || required_assets+=$'\n'
    required_assets+="${relative_path}"
    dependency_sources+=$'\n'"${canonical_path}"
  done < <(find "${REPO_DIR}/hooks" -maxdepth 1 -type f -name '*.sh' -print)

  # Follow literal helper references from the selected wrappers, hooks, and
  # libraries until their small shell dependency closure is complete.
  changed=1
  while [[ "${changed}" -eq 1 ]]; do
    changed=0
    while IFS= read -r canonical_path; do
      [[ -n "${canonical_path}" ]] || continue
      relative_path="hooks/_lib/${canonical_path##*/}"
      grep -Fqx "${relative_path}" <<< "${required_assets}" && continue
      candidate_base="${canonical_path##*/}"
      referenced=0
      while IFS= read -r source_path; do
        [[ -n "${source_path}" ]] || continue
        if grep -Fq "/${candidate_base}" "${source_path}" \
          || grep -Fq " ${candidate_base}" "${source_path}"; then
          referenced=1
          break
        fi
      done <<< "${dependency_sources}"
      [[ "${referenced}" -eq 1 ]] || continue
      [[ -z "${required_assets}" ]] || required_assets+=$'\n'
      required_assets+="${relative_path}"
      dependency_sources+=$'\n'"${canonical_path}"
      changed=1
    done < <(find "${REPO_DIR}/hooks/_lib" -maxdepth 1 -type f -name '*.sh' -print)
  done

  # pre-bash dispatches pre-commit outside the profile hook list. Derive its
  # language guard set from the canonical script, then follow local helper
  # references so protection covers the assets the runtime actually invokes.
  if grep -Fqx "pre-bash-guard.sh" <<< "${hooks}"; then
    for relative_path in hooks/pre-commit-guard.sh hooks/log.sh; do
      if ! grep -Fqx "${relative_path}" <<< "${required_assets}"; then
        [[ -z "${required_assets}" ]] || required_assets+=$'\n'
        required_assets+="${relative_path}"
        dependency_sources+=$'\n'"${REPO_DIR}/${relative_path}"
      fi
    done
    while IFS= read -r relative_path; do
      [[ -n "${relative_path}" ]] || continue
      if ! grep -Fqx "${relative_path}" <<< "${required_assets}"; then
        required_assets+=$'\n'"${relative_path}"
        dependency_sources+=$'\n'"${REPO_DIR}/${relative_path}"
      fi
    done < <(
      sed -n 's#.*${GUARDS_DIR}/\([^}"[:space:]]*\).*#guards/\1#p' \
        "${REPO_DIR}/hooks/pre-commit-guard.sh" | sort -u
    )

    changed=1
    while [[ "${changed}" -eq 1 ]]; do
      changed=0
      while IFS= read -r guard_source; do
        [[ "${guard_source}" == "${REPO_DIR}/guards/"* ]] || continue
        guard_dir="${guard_source%/*}"
        while IFS= read -r guard_candidate; do
          candidate_base="${guard_candidate##*/}"
          grep -Fq "/${candidate_base}" "${guard_source}" || continue
          relative_path="${guard_candidate#"${REPO_DIR}/"}"
          grep -Fqx "${relative_path}" <<< "${required_assets}" && continue
          required_assets+=$'\n'"${relative_path}"
          dependency_sources+=$'\n'"${guard_candidate}"
          changed=1
        done < <(find "${guard_dir}" -maxdepth 1 -type f -print)
      done <<< "${dependency_sources}"
    done
  fi

  while IFS= read -r relative_path; do
    [[ -n "${relative_path}" ]] || continue
    canonical_asset_problem \
      "${source_root}/${relative_path}" "${REPO_DIR}/${relative_path}" \
      "hook asset" || return $?
  done <<< "${required_assets}"
  return 0
}

hook_policy_problem() {
  local host="$1" hook="$2" output status=0 enforcement user_config policy_cwd
  if [[ "${host}" == "gemini" ]]; then
    unset VIBEGUARD_PROJECT_CONFIG
    user_config="${_VG_CONFIG_FILE:-${HOME}/.vibeguard/config.json}"
    policy_cwd="${project_root}"
  else
    user_config="${VG_INTERNAL_CONFIG_FILE:-${_VG_CONFIG_FILE:-${VIBEGUARD_CONFIG_FILE:-${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}/config.json}}}"
    policy_cwd="${effective_policy_cwd}"
  fi
  output="$(
    VG_INTERNAL_USER_CONFIG_FILE="${user_config}" \
    VIBEGUARD_USER_CONFIG_FILE="${user_config}" \
      "${runtime}" runtime-policy-check --cwd "${policy_cwd}" "${hook}" 2>/dev/null
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
  local host="$1" hooks="$2" hook result status
  while IFS= read -r hook; do
    [[ -n "${hook}" ]] || continue
    result=""
    status=0
    result="$(hook_policy_problem "${host}" "${hook}")" || status=$?
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
  if [[ "${host}" != "gemini" && -n "${execution_problem}" ]]; then
    printf '%s' "${execution_problem}"
    return 0
  fi
  if [[ -n "${installed_runtime_problem}" \
    && ( "${host}" == "gemini" || "${execution_mode}" != "dev-linked-repo" ) ]]; then
    printf '%s' "${installed_runtime_problem}"
    return 0
  fi
  if [[ "${host}" != "gemini" && -n "${runtime_override_problem}" ]]; then
    printf '%s' "${runtime_override_problem}"
    return 0
  fi
  if [[ "${host}" != "gemini" && -n "${policy_runtime_override_problem}" ]]; then
    printf '%s' "${policy_runtime_override_problem}"
    return 0
  fi
  if [[ "${host}" != "gemini" && -n "${dev_linked_runtime_problem}" ]]; then
    printf '%s' "${dev_linked_runtime_problem}"
    return 0
  fi
  if [[ "${host}" != "gemini" && -n "${hook_dir_override_problem}" ]]; then
    printf '%s' "${hook_dir_override_problem}"
    return 0
  fi
  if [[ "${host}" == "gemini" && -n "${installed_root_override_problem}" ]]; then
    printf '%s' "${installed_root_override_problem}"
    return 0
  fi
  if [[ "${host}" != "gemini" && -n "${active_root_override_problem}" ]]; then
    printf '%s' "${active_root_override_problem}"
    return 0
  fi
  if [[ -n "${precommit_skip_problem}" ]]; then
    printf '%s' "${precommit_skip_problem}"
    return 0
  fi
  if [[ -n "${precommit_timeout_problem}" ]]; then
    printf '%s' "${precommit_timeout_problem}"
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
  result="$(hook_set_policy_problem "${host}" "${hooks}")" || status=$?
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
claude_settings_check_status=1
claude_settings_check_output=""
if [[ -f "${SETTINGS_FILE}" ]]; then
  claude_settings_check_status=0
  claude_settings_check_output="$(
    "${runtime}" setup-settings-check "${REPO_DIR}" "${SETTINGS_FILE}" \
      "canonical-profile-hooks:${profile}" 2>&1
  )" || claude_settings_check_status=$?
  if [[ "${claude_settings_check_status}" -eq 0 ]]; then
    claude_settings_canonical=1
  elif [[ -n "${claude_settings_check_output}" && -z "${claude_problem}" ]]; then
    claude_problem="Claude settings are malformed JSON: ${SETTINGS_FILE}"
  fi
fi
if [[ -e "${HOME}/.vibeguard/run-hook.sh" ]] \
  || { [[ -f "${SETTINGS_FILE}" ]] && grep -Fq 'run-hook.sh' "${SETTINGS_FILE}"; }; then
  claude_enabled=1
fi
if [[ -x "${HOME}/.vibeguard/run-hook.sh" ]] \
  && [[ -f "${execution_root}/hooks/pre-bash-guard.sh" ]] \
  && [[ "${claude_settings_canonical}" -eq 1 ]] \
  && [[ -z "${claude_problem}" ]]; then
  claude_configured=1
fi

codex_enabled=0
codex_configured=0
codex_hooks_file="${CODEX_DIR}/hooks.json"
codex_wrapper="${HOME}/.vibeguard/run-hook-codex.sh"
codex_config="${CODEX_DIR}/config.toml"
codex_hooks_check_status=1
codex_hooks_check_output=""
if [[ -e "${codex_wrapper}" ]] \
  || { [[ -f "${codex_hooks_file}" ]] && grep -Fq 'run-hook-codex.sh' "${codex_hooks_file}"; }; then
  codex_enabled=1
fi
codex_feature_status=""
if [[ -f "${codex_config}" ]]; then
  codex_feature_status="$("${runtime}" setup-codex-config-check-hooks "${codex_config}" 2>/dev/null || true)"
fi
if [[ "${codex_feature_status}" == "INVALID" && -z "${codex_problem}" ]]; then
  codex_problem="Codex configuration is malformed TOML: ${codex_config}"
fi
if [[ -f "${codex_hooks_file}" ]]; then
  codex_hooks_check_status=0
  codex_hooks_check_output="$(
    "${runtime}" setup-codex-hooks-check \
      "${REPO_DIR}" "${codex_hooks_file}" "${codex_wrapper}" "${profile}" 2>&1
  )" || codex_hooks_check_status=$?
  if [[ "${codex_hooks_check_status}" -ne 0 \
    && -n "${codex_hooks_check_output}" \
    && -z "${codex_problem}" ]]; then
    codex_problem="Codex hook configuration is malformed JSON: ${codex_hooks_file}"
  fi
fi
if [[ -x "${codex_wrapper}" ]] \
  && [[ -f "${execution_root}/hooks/pre-bash-guard.sh" ]] \
  && [[ "${codex_feature_status}" == "OK" ]] \
  && [[ "${codex_hooks_check_status}" -eq 0 ]] \
  && [[ -z "${codex_problem}" ]]; then
  codex_configured=1
fi

gemini_enabled=0
gemini_configured=0
gemini_settings_check_status=1
gemini_settings_check_output=""
if [[ -f "${GEMINI_ENABLED_MARKER}" ]] \
  || [[ -e "${GEMINI_WRAPPER}" ]] \
  || { [[ -f "${GEMINI_SETTINGS_FILE}" ]] \
    && grep -Fq 'run-hook-gemini.sh' "${GEMINI_SETTINGS_FILE}"; }; then
  gemini_enabled=1
fi
if [[ "${gemini_enabled}" -eq 1 && -z "${gemini_problem}" ]]; then
  if ! command -v gemini >/dev/null 2>&1; then
    gemini_problem="Gemini CLI executable is not available on PATH."
  elif ! gemini hooks --help >/dev/null 2>&1; then
    gemini_problem="Gemini CLI does not expose hook support."
  fi
fi
if [[ -f "${GEMINI_SETTINGS_FILE}" ]]; then
  gemini_settings_check_status=0
  gemini_settings_check_output="$(
    "${runtime}" setup-gemini-hooks-check \
      "${GEMINI_SETTINGS_FILE}" "${GEMINI_WRAPPER}" 2>&1
  )" || gemini_settings_check_status=$?
  if [[ "${gemini_settings_check_status}" -ne 0 \
    && -n "${gemini_settings_check_output}" \
    && -z "${gemini_problem}" ]]; then
    gemini_problem="Gemini settings are malformed JSON: ${GEMINI_SETTINGS_FILE}"
  fi
fi
if [[ "${gemini_enabled}" -eq 1 ]] \
  && [[ -f "${GEMINI_ENABLED_MARKER}" ]] \
  && [[ -x "${GEMINI_WRAPPER}" ]] \
  && [[ -x "${HOME}/.vibeguard/run-hook.sh" ]] \
  && [[ -f "${HOME}/.vibeguard/installed/hooks/pre-bash-guard.sh" ]] \
  && [[ "${gemini_settings_check_status}" -eq 0 ]] \
  && [[ -z "${gemini_problem}" ]]; then
  gemini_configured=1
fi

render_host() {
  local label="$1" enabled="$2" configured="$3" event="$4" install_command="$5" problem="$6"
  local policy_source="$7"
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
    case "${problem}" in
      Project\ policy\ *)
        printf '  Next: Update or remove the project policy in %s, then rerun protection-status.\n' \
          "${policy_source}"
        ;;
      "Gemini CLI executable is not available on PATH.")
        printf '  Next: Install or restore Gemini CLI, then rerun protection-status.\n'
        ;;
      "Gemini CLI does not expose hook support.")
        printf '  Next: Upgrade Gemini CLI to a version with hook support, then rerun protection-status.\n'
        ;;
      Codex\ configuration\ is\ malformed\ TOML:*)
        printf '  Next: Fix the malformed Codex configuration in %s, then rerun protection-status.\n' \
          "${codex_config}"
        ;;
      Claude\ settings\ are\ malformed\ JSON:*)
        printf '  Next: Fix the malformed Claude settings in %s, then rerun protection-status.\n' \
          "${SETTINGS_FILE}"
        ;;
      Codex\ hook\ configuration\ is\ malformed\ JSON:*)
        printf '  Next: Fix the malformed Codex hook configuration in %s, then rerun protection-status.\n' \
          "${codex_hooks_file}"
        ;;
      Gemini\ settings\ are\ malformed\ JSON:*)
        printf '  Next: Fix the malformed Gemini settings in %s, then rerun protection-status.\n' \
          "${GEMINI_SETTINGS_FILE}"
        ;;
      Required\ Codex\ adapter\ override\ *)
        printf '  Next: Unset VIBEGUARD_CODEX_ADAPTER_PATH or restore its canonical contents, then rerun protection-status.\n'
        ;;
      Selected\ hook\ directory\ override\ VIBEGUARD_HOOK_DIR*)
        printf '  Next: Unset VIBEGUARD_HOOK_DIR or set it to %s, then rerun protection-status.\n' \
          "${execution_root}/hooks"
        ;;
      Selected\ runtime\ override\ VIBEGUARD_RUNTIME*)
        printf '  Next: Unset VIBEGUARD_RUNTIME or replace it with a compatible runtime, then rerun protection-status.\n'
        ;;
      Selected\ policy\ runtime\ override\ VIBEGUARD_POLICY_RUNTIME*)
        printf '  Next: Unset VIBEGUARD_POLICY_RUNTIME or replace it with a compatible runtime, then rerun protection-status.\n'
        ;;
      Selected\ VibeGuard\ root\ override\ VIBEGUARD_DIR*)
        printf '  Next: Unset VIBEGUARD_DIR, then rerun protection-status.\n'
        ;;
      Pre-commit\ enforcement\ is\ disabled\ by\ VIBEGUARD_SKIP_PRECOMMIT=1.)
        printf '  Next: Unset VIBEGUARD_SKIP_PRECOMMIT, then rerun protection-status.\n'
        ;;
      Pre-commit\ timeout\ enforcement\ is\ downgraded\ by\ VIBEGUARD_PRECOMMIT_TIMEOUT_BEHAVIOR=warn.)
        printf '  Next: Unset VIBEGUARD_PRECOMMIT_TIMEOUT_BEHAVIOR, then rerun protection-status.\n'
        ;;
      *)
        printf '  Next: %s\n' "${install_command}"
        ;;
    esac
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
project_policy_source="${VIBEGUARD_PROJECT_CONFIG:-${effective_policy_cwd}/.vibeguard.json}"
render_host "Claude Code" "${claude_enabled}" "${claude_configured}" "${claude_event}" \
  "bash ${setup_entrypoint} --yes --profile ${repair_profile}" "${claude_problem}" \
  "${project_policy_source}"
printf '\n'
render_host "Codex CLI" "${codex_enabled}" "${codex_configured}" "${codex_event}" \
  "bash ${setup_entrypoint} --yes --profile ${repair_profile}" "${codex_problem}" \
  "${project_policy_source}"
printf '\n'
render_host "Gemini CLI" "${gemini_enabled}" "${gemini_configured}" "${gemini_event}" \
  "bash ${setup_entrypoint} --yes --host gemini --profile ${repair_profile}" "${gemini_problem}" \
  "${project_root}/.vibeguard.json"

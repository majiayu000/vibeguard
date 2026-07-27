#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
source "${SCRIPT_DIR}/../lib/install-state.sh"
source "${SCRIPT_DIR}/targets/claude-home.sh"
source "${SCRIPT_DIR}/targets/codex-home.sh"

PURGE_DATA=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge-data)
      PURGE_DATA=1; shift ;;
    --help|-h)
      cat <<'USAGE'
Usage: bash setup.sh --clean [--purge-data]

Options:
  --purge-data   Also remove ~/.vibeguard/projects and ~/.vibeguard/config.json
USAGE
      exit 0 ;;
    *)
      red "ERROR: unknown --clean argument: $1"
      red "Usage: bash setup.sh --clean [--purge-data]"
      exit 64 ;;
  esac
done

clean_abs_path() {
  local path="$1" base_dir="${2:-}" path_dir path_base
  if [[ "${path}" != /* ]]; then
    path="${base_dir%/}/${path}"
  fi
  path_dir="$(dirname "${path}")"
  path_base="$(basename "${path}")"
  if [[ -d "${path_dir}" ]]; then
    printf '%s/%s\n' "$(cd "${path_dir}" && pwd -P)" "${path_base}"
  else
    printf '%s\n' "${path}"
  fi
}

clean_vibeguard_hook_target() {
  local hook_name="$1"
  case "${hook_name}" in
    pre-commit|pre-push)
      clean_abs_path "${HOME}/.vibeguard/${hook_name}" "${HOME}"
      ;;
    *)
      return 1 ;;
  esac
}

clean_git_hook_is_vibeguard_owned() {
  local hook_path="$1" hook_name="$2" link_target hook_dir abs_target expected_target
  [[ -L "${hook_path}" ]] || return 1
  link_target="$(readlink "${hook_path}" 2>/dev/null || true)"
  [[ -n "${link_target}" ]] || return 1
  hook_dir="$(dirname "${hook_path}")"
  abs_target="$(clean_abs_path "${link_target}" "${hook_dir}")"
  expected_target="$(clean_vibeguard_hook_target "${hook_name}")" || return 1
  [[ "${abs_target}" == "${expected_target}" ]]
}

clean_git_hook_if_vibeguard_owned() {
  local hook_path="$1" hook_name="$2" scope="$3"
  [[ -n "${hook_path}" && -n "${hook_name}" ]] || return 0
  if [[ ! -e "${hook_path}" && ! -L "${hook_path}" ]]; then
    return 0
  fi
  if clean_git_hook_is_vibeguard_owned "${hook_path}" "${hook_name}"; then
    rm -f "${hook_path}"
    yellow "Removed ${scope} ${hook_name} git hook"
  else
    yellow "Preserved non-VibeGuard ${scope} ${hook_name} hook: ${hook_path}"
  fi
}

clean_repo_git_hooks() {
  local hook_dir hook_name
  hook_dir="$(git -C "${REPO_DIR}" rev-parse --path-format=absolute --git-path hooks 2>/dev/null || true)"
  [[ -n "${hook_dir}" ]] || return 0
  for hook_name in pre-commit pre-push; do
    clean_git_hook_if_vibeguard_owned "${hook_dir}/${hook_name}" "${hook_name}" "VibeGuard repo"
  done
}

clean_tracked_project_git_hooks() {
  local hook_path hook_name repo_dir
  [[ -f "${STATE_FILE}" ]] || return 0
  while IFS=$'\t' read -r hook_path hook_name repo_dir; do
    [[ -n "${hook_path}" && -n "${hook_name}" ]] || continue
    clean_git_hook_if_vibeguard_owned "${hook_path}" "${hook_name}" "project"
  done < <(state_list_project_hooks 2>/dev/null || {
    yellow "WARN: failed to enumerate tracked project git hooks; untracked project hooks may need manual removal" >&2
  })
}

clean_vibeguard_home() {
  local vibeguard_home="${HOME}/.vibeguard"
  [[ -d "${vibeguard_home}" ]] || return 0

  rm -f \
    "${vibeguard_home}/repo-path" \
    "${vibeguard_home}/execution-mode" \
    "${vibeguard_home}/run-hook.sh" \
    "${vibeguard_home}/run-hook-codex.sh" \
    "${vibeguard_home}/pre-commit" \
    "${vibeguard_home}/pre-push"
  rm -rf "${vibeguard_home}/installed" "${vibeguard_home}/_lib"

  if [[ "${PURGE_DATA}" == "1" ]]; then
    rm -rf "${vibeguard_home}/projects"
    rm -f "${vibeguard_home}/config.json"
    yellow "Removed VibeGuard user data (--purge-data)"
  else
    yellow "Preserved VibeGuard user data (use --purge-data to remove projects/config)"
  fi
  yellow "Removed VibeGuard executable wrappers"
}

clean_scheduled_gc() {
  local receipt="${HOME}/.vibeguard/scheduler-ownership"
  local plist="${HOME}/Library/LaunchAgents/com.vibeguard.gc.plist"
  local service="${HOME}/.config/systemd/user/vibeguard-gc.service"
  local timer="${HOME}/.config/systemd/user/vibeguard-gc.timer"
  local parsed="" kind="" first_sha="" second_sha="" actual_first="" actual_second=""
  local preserve_reason=""

  if [[ ! -e "${receipt}" && ! -L "${receipt}" ]]; then
    if [[ -e "${plist}" || -L "${plist}" || -e "${service}" || -L "${service}" \
      || -e "${timer}" || -L "${timer}" ]]; then
      yellow "Preserved scheduler files: scheduler ownership receipt is missing"
    fi
    return 0
  fi
  if [[ -L "${receipt}" || ! -f "${receipt}" ]]; then
    preserve_reason="scheduler ownership receipt is not a regular file"
  elif ! parsed="$(awk -F= '
    NR == 1 && $1 == "schema" && $2 == "1" { next }
    NR == 2 && $1 == "kind" && ($2 == "launchd" || $2 == "systemd") { kind = $2; next }
    NR == 3 && ((kind == "launchd" && $1 == "plist_sha256") || (kind == "systemd" && $1 == "service_sha256")) && $2 ~ /^[0-9a-f]{64}$/ { first = $2; next }
    NR == 4 && $1 == "timer_sha256" && $2 ~ /^[0-9a-f]{64}$/ { second = $2; next }
    { bad = 1 }
    END {
      if (!bad && ((kind == "launchd" && NR == 3) || (kind == "systemd" && NR == 4))) {
        print kind "\t" first "\t" second
        exit 0
      }
      exit 1
    }
  ' "${receipt}")"; then
    preserve_reason="scheduler ownership receipt is invalid"
  else
    IFS=$'\t' read -r kind first_sha second_sha <<< "${parsed}"
    case "${kind}" in
      launchd)
        if [[ -L "${plist}" || ! -f "${plist}" ]] \
          || ! actual_first="$(setup_runtime_sha256_file "${plist}")" \
          || [[ "${actual_first}" != "${first_sha}" ]]; then
          preserve_reason="scheduler ownership receipt does not match current launchd file"
        fi
        ;;
      systemd)
        if [[ -L "${service}" || ! -f "${service}" || -L "${timer}" || ! -f "${timer}" ]] \
          || ! actual_first="$(setup_runtime_sha256_file "${service}")" \
          || ! actual_second="$(setup_runtime_sha256_file "${timer}")" \
          || [[ "${actual_first}" != "${first_sha}" || "${actual_second}" != "${second_sha}" ]]; then
          preserve_reason="scheduler ownership receipt does not match current systemd files"
        fi
        ;;
    esac
  fi

  if [[ -n "${preserve_reason}" ]]; then
    yellow "Preserved scheduler files: ${preserve_reason}"
  elif [[ "${kind}" == "launchd" ]]; then
    launchctl bootout "gui/$(id -u)/com.vibeguard.gc" 2>/dev/null || true
    rm -f "${plist}"
    yellow "Removed scheduled GC (com.vibeguard.gc)"
  else
    if [[ "$(uname)" == "Linux" ]] && command -v systemctl &>/dev/null; then
      systemctl --user stop vibeguard-gc.timer 2>/dev/null || true
      systemctl --user disable vibeguard-gc.timer 2>/dev/null || true
    fi
    rm -f "${service}" "${timer}"
    if [[ "$(uname)" == "Linux" ]] && command -v systemctl &>/dev/null; then
      systemctl --user daemon-reload 2>/dev/null || true
    fi
    yellow "Removed scheduled GC (vibeguard-gc.timer)"
  fi

  if [[ -f "${receipt}" || -L "${receipt}" ]]; then
    rm -f "${receipt}"
  else
    yellow "Preserved non-file scheduler ownership receipt: ${receipt}"
  fi
}

echo "Cleaning VibeGuard installation..."

ensure_setup_runtime_available >/dev/null 2>&1 || true

clean_repo_git_hooks
clean_tracked_project_git_hooks
clean_claude_home_installation
clean_codex_home_installation
clean_vibeguard_home
clean_scheduled_gc

# Remove install state
state_clean
yellow "Removed install state"

green "VibeGuard cleaned."

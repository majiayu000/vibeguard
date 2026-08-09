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

cleanup_clean_lifecycle() {
  local status=0
  # Releasing the canonical lock runs the runtime, and clean_vibeguard_home may
  # already have deleted the installed binary, so the pinned copy has to outlive
  # the release. Swallowing a failed release would leave ~/.vibeguard/setup.lock
  # behind and block every later install and clean.
  if ! setup_lock_release; then
    red "ERROR: failed to release the VibeGuard setup lock; remove it before retrying"
    status=1
  fi
  setup_runtime_bootstrap_cleanup
  return "${status}"
}

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

clean_scheduler_receipt_parse() {
  awk -F= '
    NR == 1 && $1 == "schema" && $2 == "1" { next }
    NR == 2 && $1 == "kind" && ($2 == "launchd" || $2 == "systemd") { kind = $2; next }
    NR == 3 && $1 == "phase" && ($2 == "managed" || $2 == "cleaning") {
      phase = $2; declared_phase = 1; next
    }
    NR == 3 && ((kind == "launchd" && $1 == "plist_sha256") || (kind == "systemd" && $1 == "service_sha256")) && $2 ~ /^[0-9a-f]{64}$/ {
      phase = "managed"; first = $2; next
    }
    NR == 4 && declared_phase && ((kind == "launchd" && $1 == "plist_sha256") || (kind == "systemd" && $1 == "service_sha256")) && $2 ~ /^[0-9a-f]{64}$/ {
      first = $2; next
    }
    NR == 4 && !declared_phase && kind == "systemd" && $1 == "timer_sha256" && $2 ~ /^[0-9a-f]{64}$/ {
      second = $2; next
    }
    NR == 5 && declared_phase && kind == "systemd" && $1 == "timer_sha256" && $2 ~ /^[0-9a-f]{64}$/ {
      second = $2; next
    }
    { bad = 1 }
    END {
      launchd_ok = kind == "launchd" && first != "" && second == "" && ((!declared_phase && NR == 3) || (declared_phase && NR == 4))
      systemd_ok = kind == "systemd" && first != "" && second != "" && ((!declared_phase && NR == 4) || (declared_phase && NR == 5))
      if (!bad && phase != "" && (launchd_ok || systemd_ok)) {
        print kind "\t" phase "\t" first "\t" second
        exit 0
      }
      exit 1
    }
  ' "$1"
}

clean_scheduler_receipt_write_phase() {
  local receipt="$1" kind="$2" phase="$3" first_sha="$4" second_sha="${5:-}"
  local temporary parsed parsed_kind parsed_phase parsed_first parsed_second
  temporary="$(mktemp "$(dirname "${receipt}")/.scheduler-ownership.XXXXXX")"
  if [[ "${kind}" == "launchd" ]]; then
    printf 'schema=1\nkind=launchd\nphase=%s\nplist_sha256=%s\n' \
      "${phase}" "${first_sha}" > "${temporary}"
  else
    printf 'schema=1\nkind=systemd\nphase=%s\nservice_sha256=%s\ntimer_sha256=%s\n' \
      "${phase}" "${first_sha}" "${second_sha}" > "${temporary}"
  fi
  chmod 600 "${temporary}"
  if ! mv -f -- "${temporary}" "${receipt}"; then
    rm -f -- "${temporary}"
    return 1
  fi
  [[ -f "${receipt}" && ! -L "${receipt}" ]] || return 1
  parsed="$(clean_scheduler_receipt_parse "${receipt}")" || return 1
  IFS=$'\t' read -r parsed_kind parsed_phase parsed_first parsed_second <<< "${parsed}"
  [[ "${parsed_kind}" == "${kind}" && "${parsed_phase}" == "${phase}" \
    && "${parsed_first}" == "${first_sha}" && "${parsed_second}" == "${second_sha}" ]]
}

clean_scheduler_verify_before_remove() {
  local path="$1" expected_sha="$2" label="$3" actual_sha
  if [[ ! -e "${path}" && ! -L "${path}" ]]; then
    return 0
  fi
  if [[ -L "${path}" || ! -f "${path}" ]] \
    || ! actual_sha="$(setup_runtime_sha256_file "${path}")" \
    || [[ "${actual_sha}" != "${expected_sha}" ]]; then
    red "ERROR: scheduled GC ${label} changed after scheduler deactivation; preserving file and cleaning receipt: ${path}"
    return 1
  fi
}

clean_launchd_scheduler_deactivate() {
  local label="gui/$(id -u)/com.vibeguard.gc"
  [[ "$(uname)" == "Darwin" ]] || return 0
  if ! command -v launchctl >/dev/null 2>&1; then
    red "ERROR: cannot deactivate scheduled GC: launchctl is unavailable; preserving launchd plist and cleaning receipt"
    return 1
  fi
  if launchctl print "${label}" >/dev/null 2>&1; then
    if ! launchctl bootout "${label}" >/dev/null 2>&1; then
      red "ERROR: failed to deactivate scheduled GC launchd job; preserving launchd plist and cleaning receipt"
      return 1
    fi
    if launchctl print "${label}" >/dev/null 2>&1; then
      red "ERROR: scheduled GC launchd job remains loaded after bootout; preserving launchd plist and cleaning receipt"
      return 1
    fi
  fi
}

clean_systemd_stop_and_verify_unit() {
  local unit="$1" label="$2"
  local stop_rc=0 active_state="" active_rc=0
  systemctl --user stop "${unit}" >/dev/null 2>&1 || stop_rc=$?
  active_state="$(
    LC_ALL=C systemctl --user is-active "${unit}" 2>/dev/null
  )" || active_rc=$?
  case "${active_state}" in
    inactive|failed|unknown)
      return 0
      ;;
    *)
      if [[ "${stop_rc}" -ne 0 ]]; then
        red "ERROR: failed to stop scheduled GC ${label}; ${label} is not proven inactive (stop_rc=${stop_rc}, state=${active_state:-empty}, rc=${active_rc}); preserving systemd units and cleaning receipt"
      else
        red "ERROR: scheduled GC ${label} is not proven inactive after stop (state=${active_state:-empty}, rc=${active_rc}); preserving systemd units and cleaning receipt"
      fi
      return 1
      ;;
  esac
}

clean_systemd_scheduler_deactivate() {
  local disable_rc=0 runtime_disable_rc=0 enabled_state="" enabled_rc=0
  [[ "$(uname)" == "Linux" ]] || return 0
  if ! command -v systemctl >/dev/null 2>&1; then
    red "ERROR: cannot deactivate scheduled GC: systemctl is unavailable; preserving systemd units and cleaning receipt"
    return 1
  fi
  clean_systemd_stop_and_verify_unit \
    vibeguard-gc.timer "systemd timer" || return 1
  clean_systemd_stop_and_verify_unit \
    vibeguard-gc.service "systemd service" || return 1
  systemctl --user disable vibeguard-gc.timer >/dev/null 2>&1 || disable_rc=$?
  systemctl --user disable --runtime vibeguard-gc.timer >/dev/null 2>&1 \
    || runtime_disable_rc=$?
  enabled_state="$(
    LC_ALL=C systemctl --user is-enabled vibeguard-gc.timer 2>/dev/null
  )" || enabled_rc=$?
  case "${enabled_state}" in
    disabled|masked|not-found)
      ;;
    *)
      if [[ "${disable_rc}" -ne 0 || "${runtime_disable_rc}" -ne 0 ]]; then
        red "ERROR: failed to disable scheduled GC systemd timer; timer is not proven disabled (disable_rc=${disable_rc}, runtime_disable_rc=${runtime_disable_rc}, state=${enabled_state:-empty}, rc=${enabled_rc}); preserving systemd units and cleaning receipt"
      else
        red "ERROR: scheduled GC systemd timer is not proven disabled (state=${enabled_state:-empty}, rc=${enabled_rc}); preserving systemd units and cleaning receipt"
      fi
      return 1
      ;;
  esac
}

clean_legacy_launchd_scheduler_owned() {
  local plist="$1"
  [[ -f "${plist}" && ! -L "${plist}" ]] \
    && grep -qF '<string>com.vibeguard.gc</string>' "${plist}" \
    && grep -Eq '<string>[^<]*/scripts/gc/gc-scheduled\.sh</string>' "${plist}" \
    && grep -qF '<string>--scheduled</string>' "${plist}"
}

clean_legacy_systemd_scheduler_owned() {
  local service="$1" timer="$2"
  [[ -f "${service}" && ! -L "${service}" \
    && -f "${timer}" && ! -L "${timer}" ]] \
    && grep -qFx 'Description=VibeGuard Scheduled GC' "${service}" \
    && grep -Eq '^ExecStart=/bin/bash ".*[/]scripts/gc/gc-scheduled\.sh"$' "${service}" \
    && grep -qFx 'Description=VibeGuard Scheduled GC Timer' "${timer}" \
    && grep -qFx 'Unit=vibeguard-gc.service' "${timer}"
}

clean_scheduled_gc() {
  local receipt="${HOME}/.vibeguard/scheduler-ownership"
  local plist="${HOME}/Library/LaunchAgents/com.vibeguard.gc.plist"
  local service="${HOME}/.config/systemd/user/vibeguard-gc.service"
  local timer="${HOME}/.config/systemd/user/vibeguard-gc.timer"
  local parsed="" kind="" phase="" first_sha="" second_sha=""
  local actual_first="" actual_second="" preserve_reason=""

  if [[ ! -e "${receipt}" && ! -L "${receipt}" ]]; then
    if [[ ! -e "${plist}" && ! -L "${plist}" \
      && ! -e "${service}" && ! -L "${service}" \
      && ! -e "${timer}" && ! -L "${timer}" ]]; then
      return 0
    fi
    if [[ ! -e "${service}" && ! -L "${service}" \
      && ! -e "${timer}" && ! -L "${timer}" ]] \
      && clean_legacy_launchd_scheduler_owned "${plist}"; then
      kind="launchd"
      phase="cleaning"
      first_sha="$(setup_runtime_sha256_file "${plist}")"
    elif [[ ! -e "${plist}" && ! -L "${plist}" ]] \
      && clean_legacy_systemd_scheduler_owned "${service}" "${timer}"; then
      kind="systemd"
      phase="cleaning"
      first_sha="$(setup_runtime_sha256_file "${service}")"
      second_sha="$(setup_runtime_sha256_file "${timer}")"
    else
      yellow "Preserved scheduler files: scheduler ownership receipt is missing"
      return 1
    fi
    mkdir -p "$(dirname "${receipt}")"
    clean_scheduler_receipt_write_phase \
      "${receipt}" "${kind}" "${phase}" "${first_sha}" "${second_sha}"
  fi
  if [[ -L "${receipt}" || ! -f "${receipt}" ]]; then
    yellow "Preserved scheduler files and receipt: scheduler ownership receipt is not a regular file"
    return 1
  fi
  if ! parsed="$(clean_scheduler_receipt_parse "${receipt}")"; then
    yellow "Preserved scheduler files and receipt: scheduler ownership receipt is invalid"
    return 1
  fi
  IFS=$'\t' read -r kind phase first_sha second_sha <<< "${parsed}"

  case "${kind}" in
    launchd)
      if [[ -e "${plist}" || -L "${plist}" ]]; then
        if [[ -L "${plist}" || ! -f "${plist}" ]] \
          || ! actual_first="$(setup_runtime_sha256_file "${plist}")" \
          || [[ "${actual_first}" != "${first_sha}" ]]; then
          preserve_reason="scheduler ownership receipt does not match current launchd file"
        fi
      elif [[ "${phase}" == "managed" ]]; then
        preserve_reason="scheduler ownership receipt does not match current launchd file"
      fi
      ;;
    systemd)
      if [[ -e "${service}" || -L "${service}" ]]; then
        if [[ -L "${service}" || ! -f "${service}" ]] \
          || ! actual_first="$(setup_runtime_sha256_file "${service}")" \
          || [[ "${actual_first}" != "${first_sha}" ]]; then
          preserve_reason="scheduler ownership receipt does not match current systemd files"
        fi
      elif [[ "${phase}" == "managed" ]]; then
        preserve_reason="scheduler ownership receipt does not match current systemd files"
      fi
      if [[ -e "${timer}" || -L "${timer}" ]]; then
        if [[ -L "${timer}" || ! -f "${timer}" ]] \
          || ! actual_second="$(setup_runtime_sha256_file "${timer}")" \
          || [[ "${actual_second}" != "${second_sha}" ]]; then
          preserve_reason="scheduler ownership receipt does not match current systemd files"
        fi
      elif [[ "${phase}" == "managed" ]]; then
        preserve_reason="scheduler ownership receipt does not match current systemd files"
      fi
      ;;
  esac
  if [[ -n "${preserve_reason}" ]]; then
    yellow "Preserved scheduler files and receipt: ${preserve_reason}"
    return 1
  fi

  if [[ "${phase}" == "managed" ]]; then
    clean_scheduler_receipt_write_phase \
      "${receipt}" "${kind}" cleaning "${first_sha}" "${second_sha}"
  fi
  if [[ "${kind}" == "launchd" ]]; then
    clean_launchd_scheduler_deactivate || return 1
    clean_scheduler_verify_before_remove \
      "${plist}" "${first_sha}" "launchd plist" || return 1
    [[ ! -e "${plist}" && ! -L "${plist}" ]] || rm -f -- "${plist}"
    [[ ! -e "${plist}" && ! -L "${plist}" ]] || return 1
    yellow "Removed scheduled GC (com.vibeguard.gc)"
  else
    clean_systemd_scheduler_deactivate || return 1
    clean_scheduler_verify_before_remove \
      "${service}" "${first_sha}" "systemd service" || return 1
    [[ ! -e "${service}" && ! -L "${service}" ]] || rm -f -- "${service}"
    clean_scheduler_verify_before_remove \
      "${timer}" "${second_sha}" "systemd timer" || return 1
    [[ ! -e "${timer}" && ! -L "${timer}" ]] || rm -f -- "${timer}"
    [[ ! -e "${service}" && ! -L "${service}" \
      && ! -e "${timer}" && ! -L "${timer}" ]] || return 1
    if [[ "$(uname)" == "Linux" ]]; then
      if ! systemctl --user daemon-reload >/dev/null 2>&1; then
        red "ERROR: failed to reload systemd after scheduled GC removal; preserving cleaning receipt"
        return 1
      fi
    fi
    yellow "Removed scheduled GC (vibeguard-gc.timer)"
  fi
  rm -f -- "${receipt}"
  [[ ! -e "${receipt}" && ! -L "${receipt}" ]]
}

echo "Cleaning VibeGuard installation..."

if ! ensure_setup_runtime_available >/dev/null 2>&1; then
  red "ERROR: vibeguard-runtime is required to safely remove managed high-context files"
  exit 1
fi
if ! pin_setup_runtime_for_clean; then
  red "ERROR: failed to preserve vibeguard-runtime for the full clean lifecycle"
  exit 1
fi
if ! setup_lock_acquire; then
  exit 1
fi
trap cleanup_clean_lifecycle EXIT
state_prepare_clean

clean_repo_git_hooks
clean_tracked_project_git_hooks
clean_claude_home_installation
clean_codex_home_installation
clean_vibeguard_home
clean_scheduled_gc

# Remove install state
state_clean
if [[ "${_VG_STATE_CLEAN_RESULT:-}" == "RETAINED" ]]; then
  yellow "Retained install state for ${_VG_STATE_CLEAN_QUARANTINE_COUNT} disabled-skill quarantine(s): ${STATE_FILE}"
else
  yellow "Removed install state"
fi

setup_lock_release
green "VibeGuard cleaned."

#!/usr/bin/env bash
# VibeGuard Hook Wrapper — A hook distributor compatible with all platforms
#
# All hooks in settings.json are called indirectly through this wrapper.
# Stable installs execute the installed snapshot. Live-repo execution is only
# allowed when setup explicitly wrote dev-linked mode.
#
# Usage: bash ~/.vibeguard/run-hook.sh <hook-script-name> [args...]
# Example: bash ~/.vibeguard/run-hook.sh stop-guard.sh

set -euo pipefail

WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export VIBEGUARD_WRAPPER="${VIBEGUARD_WRAPPER:-run-hook.sh}"
export VIBEGUARD_SOURCE_CONFIG="${VIBEGUARD_SOURCE_CONFIG:-${HOME}/.claude/settings.json}"
export VIBEGUARD_HOOK_PROTOCOL_VERSION="${VIBEGUARD_HOOK_PROTOCOL_VERSION:-claude-code-hooks-v1}"
export VIBEGUARD_CALLER_EVIDENCE="${VIBEGUARD_CALLER_EVIDENCE:-wrapper-and-parent-process}"

HOOK_NAME="${1:?Usage: run-hook.sh <hook-name>}"
shift

_VG_HOOK_STDIN_FILE=""
_vg_cleanup_hook_stdin() {
  if [[ -n "${_VG_HOOK_STDIN_FILE}" ]]; then
    rm -f "${_VG_HOOK_STDIN_FILE}" 2>/dev/null || true
  fi
}
trap _vg_cleanup_hook_stdin EXIT

if [[ ! -t 0 ]]; then
  _VG_HOOK_STDIN_FILE="$(mktemp "${TMPDIR:-/tmp}/vibeguard-hook-stdin.XXXXXX")"
  if ! cat > "${_VG_HOOK_STDIN_FILE}"; then
    echo "ERROR: failed to drain hook stdin for ${HOOK_NAME}" >&2
    exit 1
  fi
fi

INSTALLED_DIR="${HOME}/.vibeguard/installed/hooks"
REPO_PATH_FILE="${HOME}/.vibeguard/repo-path"
EXECUTION_MODE_FILE="${HOME}/.vibeguard/execution-mode"

vibeguard_execution_mode() {
  local mode="${VIBEGUARD_EXECUTION_MODE:-}"
  if [[ -z "${mode}" && -f "${EXECUTION_MODE_FILE}" ]]; then
    mode="$(tr -d '[:space:]' < "${EXECUTION_MODE_FILE}")"
  fi
  case "${mode}" in
    dev-linked|dev-linked-repo|repo|repo-linked)
      printf '%s\n' "dev-linked-repo" ;;
    *)
      printf '%s\n' "installed-snapshot" ;;
  esac
}

EXECUTION_MODE="$(vibeguard_execution_mode)"
if [[ "${EXECUTION_MODE}" == "dev-linked-repo" ]]; then
  if [[ ! -f "$REPO_PATH_FILE" ]]; then
    echo "ERROR: ${REPO_PATH_FILE} not found. Re-run: bash <vibeguard-repo>/scripts/setup/install.sh" >&2
    exit 1
  fi
  REPO_DIR=$(<"$REPO_PATH_FILE")
  HOOK_PATH="${REPO_DIR}/hooks/${HOOK_NAME}"
else
  HOOK_PATH="${INSTALLED_DIR}/${HOOK_NAME}"
  if [[ ! -d "$INSTALLED_DIR" ]]; then
    echo "ERROR: installed VibeGuard hook snapshot not found: ${INSTALLED_DIR}" >&2
    echo "Re-run: bash <vibeguard-repo>/scripts/setup/install.sh --yes" >&2
    exit 1
  fi
fi

if [[ ! -f "$HOOK_PATH" ]]; then
  echo "ERROR: hook not found: ${HOOK_PATH}" >&2
  exit 1
fi

if [[ "${EXECUTION_MODE}" == "dev-linked-repo" ]]; then
  WRAPPER_ENV_PATH="$(dirname "${HOOK_PATH}")/_lib/wrapper_env.sh"
  [[ -f "${WRAPPER_ENV_PATH}" ]] || WRAPPER_ENV_PATH="${WRAPPER_DIR}/_lib/wrapper_env.sh"
else
  WRAPPER_ENV_PATH="${INSTALLED_DIR}/_lib/wrapper_env.sh"
  [[ -f "${WRAPPER_ENV_PATH}" ]] || WRAPPER_ENV_PATH="${WRAPPER_DIR}/_lib/wrapper_env.sh"
fi
if [[ -f "${WRAPPER_ENV_PATH}" ]]; then
  # shellcheck source=hooks/_lib/wrapper_env.sh
  source "${WRAPPER_ENV_PATH}"
  vg_wrapper_env_export "claude"
fi

if [[ "${EXECUTION_MODE}" == "dev-linked-repo" ]]; then
  POLICY_PATH="$(dirname "${HOOK_PATH}")/_lib/policy.sh"
  [[ -f "${POLICY_PATH}" ]] || POLICY_PATH="${WRAPPER_DIR}/_lib/policy.sh"
else
  POLICY_PATH="${INSTALLED_DIR}/_lib/policy.sh"
  [[ -f "${POLICY_PATH}" ]] || POLICY_PATH="${WRAPPER_DIR}/_lib/policy.sh"
fi
if [[ ! -f "${POLICY_PATH}" ]]; then
  echo "ERROR: VibeGuard policy helper not found for ${HOOK_NAME}" >&2
  exit 1
fi
# shellcheck source=hooks/_lib/policy.sh
source "${POLICY_PATH}"
policy_status=0
vg_policy_check_hook "${HOOK_NAME}" "${_VG_HOOK_STDIN_FILE:-}" || policy_status=$?
export VIBEGUARD_POLICY_ENFORCEMENT="${VG_POLICY_ENFORCEMENT:-block}"
if [[ ${policy_status} -eq 10 ]]; then
  vg_policy_diag "${HOOK_NAME}" "Claude" "${VG_POLICY_KIND}" "${VG_POLICY_REASON}"
  exit 0
elif [[ ${policy_status} -ne 0 ]]; then
  CLAUDE_EVENT_NAME="$(vg_policy_claude_event_name "${HOOK_NAME}" "${_VG_HOOK_STDIN_FILE:-}")"
  vg_policy_diag "${HOOK_NAME}" "${CLAUDE_EVENT_NAME}" "${VG_POLICY_KIND}" "${VG_POLICY_REASON}"
  if vg_policy_claude_event_enforces "${CLAUDE_EVENT_NAME}"; then
    vg_policy_claude_error_output "${VG_POLICY_REASON}"
    exit 0
  fi
  printf '%s\n' "${VG_POLICY_REASON}" >&2
  exit 0
fi

# Ensure Python writes UTF-8 regardless of the terminal's default encoding (fixes Windows CP-1252)
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

if [[ "${VIBEGUARD_POLICY_ENFORCEMENT}" == "warn" || "${VG_POLICY_OUTPUT_FILTER:-0}" == "1" ]]; then
  hook_output=""
  hook_status=0
  # Separate stderr from stdout: only stdout feeds the JSON downgrade path.
  # Mixing stderr in (2>&1) corrupts the JSON parsed by vg_policy_downgrade_output.
  hook_err_file="$(mktemp "${TMPDIR:-/tmp}/vibeguard-warn-hook.XXXXXX")"
  if [[ -n "${_VG_HOOK_STDIN_FILE}" ]]; then
    hook_output="$(bash "$HOOK_PATH" "$@" < "${_VG_HOOK_STDIN_FILE}" 2>"${hook_err_file}")" || hook_status=$?
  else
    hook_output="$(bash "$HOOK_PATH" "$@" 2>"${hook_err_file}")" || hook_status=$?
  fi
  if [[ -s "${hook_err_file}" ]]; then
    cat "${hook_err_file}" >&2
  fi
  rm -f "${hook_err_file}" 2>/dev/null || true
  if [[ -n "${hook_output}" ]]; then
    vg_policy_downgrade_output "${hook_output}" "${HOOK_NAME}"
  fi
  exit "${hook_status}"
fi

if [[ -z "${_VG_HOOK_STDIN_FILE}" ]]; then
  trap - EXIT
  exec bash "$HOOK_PATH" "$@"
fi

hook_status=0
bash "$HOOK_PATH" "$@" < "${_VG_HOOK_STDIN_FILE}" || hook_status=$?
exit "${hook_status}"

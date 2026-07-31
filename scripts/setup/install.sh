#!/usr/bin/env bash
set -euo pipefail
# VibeGuard Setup Script
# One-click deployment of anti-hallucination specifications to ~/.claude/ and ~/.codex/
#
# How to use:
# bash setup.sh # Install (default core)
# bash setup.sh --profile full # Install full (including Stop signal/Build Check)
# bash setup.sh --profile minimal # Minimal installation (pre-hooks only)
# bash setup.sh --profile strict # Strict mode (full hooks + Claude Code U-32 SessionStart constraint budget)
# bash setup.sh --languages rust,python # Only install rules and guards for the specified language
# bash setup.sh --profile full --languages rust # Use in combination
# bash setup.sh --dry-run # Show high-context diffs without writing
# bash setup.sh --yes # Apply high-context diffs non-interactively
# bash setup.sh --build-from-source # Build vibeguard-runtime with cargo instead of downloading a release binary
# bash setup.sh --runtime-version v1.2.3 # Download a specific vibeguard-runtime release tag
# bash setup.sh --require-provenance # Require GitHub artifact attestation verification for release binaries
# bash setup.sh --with-scheduler # Opt in to launchd/systemd scheduled GC
# bash setup.sh --repair-stale-unmanaged-hooks # Opt in to prune missing-target Codex PreToolUse/PermissionRequest hooks
# bash setup.sh --force-overwrite # Replace user-customized managed files/commands
# bash setup.sh --dev-linked # Opt in to live-repo execution for local development
# bash setup.sh --check # Check status only
# bash setup.sh --clean # Clean installation
# bash setup.sh --clean --purge-data # Clean installation and remove projects/config
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
source "${SCRIPT_DIR}/../lib/install-state.sh"
source "${SCRIPT_DIR}/../lib/project_config.sh"
source "${SCRIPT_DIR}/targets/claude-home.sh"
source "${SCRIPT_DIR}/targets/codex-home.sh"
source "${SCRIPT_DIR}/runtime-install.sh"
# --- Mode dispatch ---
case "${1:-}" in
  --check) shift; exec bash "${SCRIPT_DIR}/check.sh" "$@" ;;
  --clean) shift; exec bash "${SCRIPT_DIR}/clean.sh" "$@" ;;
  --codex-status) shift; exec bash "${SCRIPT_DIR}/codex-status.sh" "$@" ;;
esac
# --- Argument parsing ---
PROFILE="${VIBEGUARD_SETUP_PROFILE:-core}"
LANGUAGES=""
VIBEGUARD_SETUP_DRY_RUN="${VIBEGUARD_SETUP_DRY_RUN:-0}"
VIBEGUARD_SETUP_AUTO="${VIBEGUARD_SETUP_AUTO:-0}"
VIBEGUARD_SETUP_FORCE_OVERWRITE="${VIBEGUARD_SETUP_FORCE_OVERWRITE:-0}"
WITH_SCHEDULER="${VIBEGUARD_SETUP_WITH_SCHEDULER:-0}"
REPAIR_STALE_UNMANAGED_HOOKS="${VIBEGUARD_SETUP_REPAIR_STALE_UNMANAGED_HOOKS:-0}"
BUILD_FROM_SOURCE="${VIBEGUARD_SETUP_BUILD_FROM_SOURCE:-0}"
REQUIRE_PROVENANCE="${VIBEGUARD_SETUP_REQUIRE_PROVENANCE:-0}"
DEV_LINKED="${VIBEGUARD_SETUP_DEV_LINKED:-0}"
VIBEGUARD_HOME="${HOME}/.vibeguard"
_INSTALL_TMP=""
_INSTALL_FINAL_TMP=""
RUNTIME_VERSION_OVERRIDE=""
RUNTIME_VERSION_OVERRIDE_SET=0
RUNTIME_PROVENANCE_STATUS=""
RUNTIME_PROVENANCE_REASON=""
RUNTIME_PROVENANCE_RELEASE_REPO=""
RUNTIME_PROVENANCE_TAG=""
RUNTIME_PROVENANCE_TARGET=""
RUNTIME_PROVENANCE_SHA256=""
if [[ -n "${VIBEGUARD_SETUP_RUNTIME_VERSION+x}" ]]; then
  RUNTIME_VERSION_OVERRIDE="${VIBEGUARD_SETUP_RUNTIME_VERSION}"
  RUNTIME_VERSION_OVERRIDE_SET=1
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      VIBEGUARD_SETUP_DRY_RUN=1; shift ;;
    --yes|-y)
      VIBEGUARD_SETUP_AUTO=1; shift ;;
    --build-from-source)
      BUILD_FROM_SOURCE=1; shift ;;
    --runtime-version)
      [[ $# -lt 2 ]] && { red "ERROR: --runtime-version requires a value (e.g. v1.2.3)"; exit 1; }
      RUNTIME_VERSION_OVERRIDE="$2"; RUNTIME_VERSION_OVERRIDE_SET=1; shift 2 ;;
    --runtime-version=*)
      RUNTIME_VERSION_OVERRIDE="${1#*=}"; RUNTIME_VERSION_OVERRIDE_SET=1; shift ;;
    --require-provenance)
      REQUIRE_PROVENANCE=1; shift ;;
    --with-scheduler)
      WITH_SCHEDULER=1; shift ;;
    --repair-stale-unmanaged-hooks)
      REPAIR_STALE_UNMANAGED_HOOKS=1; shift ;;
    --force-overwrite)
      VIBEGUARD_SETUP_FORCE_OVERWRITE=1; shift ;;
    --dev-linked)
      DEV_LINKED=1; shift ;;
    --profile)
      [[ $# -lt 2 ]] && { red "ERROR: --profile requires a value (minimal|core|full|strict)"; exit 1; }
      PROFILE="$2"; shift 2 ;;
    --profile=*)
      PROFILE="${1#*=}"; shift ;;
    --languages)
      [[ $# -lt 2 ]] && { red "ERROR: --languages requires a value (e.g. rust,python,go,typescript)"; exit 1; }
      LANGUAGES="$2"; shift 2 ;;
    --languages=*)
      LANGUAGES="${1#*=}"; shift ;;
    *)
      red "ERROR: unknown argument: $1"
      red "Usage: bash setup.sh [--yes] [--dry-run] [--build-from-source] [--runtime-version vX.Y.Z] [--require-provenance] [--with-scheduler] [--repair-stale-unmanaged-hooks] [--force-overwrite] [--dev-linked] [--profile minimal|core|full|strict] [--languages lang1,lang2] | --check | --clean [--purge-data]"
      exit 1 ;;
  esac
done
export VIBEGUARD_SETUP_DRY_RUN VIBEGUARD_SETUP_AUTO VIBEGUARD_SETUP_FORCE_OVERWRITE
export VIBEGUARD_SETUP_REPAIR_STALE_UNMANAGED_HOOKS="${REPAIR_STALE_UNMANAGED_HOOKS}"
export VIBEGUARD_SETUP_REQUIRE_PROVENANCE="${REQUIRE_PROVENANCE}"
export VIBEGUARD_SETUP_DEV_LINKED="${DEV_LINKED}"
if [[ "${RUNTIME_VERSION_OVERRIDE_SET}" == "1" && -z "${RUNTIME_VERSION_OVERRIDE}" ]]; then
  red "ERROR: --runtime-version requires a non-empty value (e.g. v1.2.3)"
  exit 1
fi
if [[ "${VIBEGUARD_PAYLOAD_MODE:-0}" == "1" ]]; then
  payload_version="$(
    awk -F= '$1 == "version" { print $2; exit }' \
      "${REPO_DIR}/.vibeguard-payload" 2>/dev/null \
      | tr -d '[:space:]'
  )"
  payload_version="${payload_version#v}"
  if [[ -z "${payload_version}" ]]; then
    red "ERROR: payload marker does not declare a version; refusing an unpinned install."
    exit 1
  fi
  if [[ "${RUNTIME_VERSION_OVERRIDE_SET}" == "1" ]]; then
    normalized_runtime_override="${RUNTIME_VERSION_OVERRIDE#v}"
    if [[ "${normalized_runtime_override}" != "${payload_version}" ]]; then
      red "ERROR: runtime version override ${RUNTIME_VERSION_OVERRIDE} does not match payload version ${payload_version}; payload installs cannot select a different runtime release."
      exit 1
    fi
  fi
  if [[ "${DEV_LINKED}" == "1" ]]; then
    red "ERROR: --dev-linked is not available in payload mode; payload installs must use the durable installed snapshot."
    exit 1
  fi
fi
if [[ "${RUNTIME_VERSION_OVERRIDE_SET}" == "1" ]]; then
  export VIBEGUARD_SETUP_RUNTIME_VERSION="${RUNTIME_VERSION_OVERRIDE}"
fi
case "${REQUIRE_PROVENANCE}" in
  0|1) ;;
  *) red "ERROR: VIBEGUARD_SETUP_REQUIRE_PROVENANCE must be 0 or 1"; exit 1 ;;
esac
if [[ "${REQUIRE_PROVENANCE}" == "1" && "${BUILD_FROM_SOURCE}" == "1" ]]; then
  red "ERROR: --require-provenance cannot be combined with --build-from-source; release provenance is only available for downloaded release binaries."
  exit 1
fi
if [[ "${VIBEGUARD_PAYLOAD_MODE:-0}" == "1" && "${BUILD_FROM_SOURCE}" == "1" ]]; then
  red "ERROR: --build-from-source is not available in payload mode; payload installs use the pinned release binary only. Clone the repository for source builds."
  exit 1
fi
case "${PROFILE}" in
  minimal|core|full|strict) ;;
  *) red "ERROR: unsupported profile: ${PROFILE} (expected minimal|core|full|strict)"; exit 1 ;;
esac
# Parse languages into array
declare -a LANG_FILTER=()
if [[ -n "$LANGUAGES" ]]; then
  IFS=',' read -ra LANG_FILTER <<< "$LANGUAGES"
fi
SCHEDULER_REPO_DIR="${REPO_DIR}"
SCHEDULER_REFRESHED=0
SCHEDULER_PRESERVE_REASON=""
SCHEDULER_RECEIPT="${VIBEGUARD_HOME}/scheduler-ownership"
SCHEDULER_PLATFORM="$(uname)"
SCHEDULER_PLATFORM_KIND=""
case "${SCHEDULER_PLATFORM}" in
  Darwin) SCHEDULER_PLATFORM_KIND="launchd" ;;
  Linux) SCHEDULER_PLATFORM_KIND="systemd" ;;
esac
if [[ "${VIBEGUARD_PAYLOAD_MODE:-0}" == "1" \
  && -L "${HOME}/.vibeguard/dist/current" \
  && -f "${HOME}/.vibeguard/dist/current/scripts/gc/gc-scheduled.sh" ]]; then
  SCHEDULER_REPO_DIR="${HOME}/.vibeguard/dist/current"
fi
scheduler_files_exist() {
  [[ -e "${HOME}/Library/LaunchAgents/com.vibeguard.gc.plist" \
    || -L "${HOME}/Library/LaunchAgents/com.vibeguard.gc.plist" \
    || -e "${HOME}/.config/systemd/user/vibeguard-gc.service" \
    || -L "${HOME}/.config/systemd/user/vibeguard-gc.service" \
    || -e "${HOME}/.config/systemd/user/vibeguard-gc.timer" \
    || -L "${HOME}/.config/systemd/user/vibeguard-gc.timer" ]]
}
scheduler_wrong_platform_files_exist() {
  case "$1" in
    launchd)
      [[ -e "${HOME}/.config/systemd/user/vibeguard-gc.service" \
        || -L "${HOME}/.config/systemd/user/vibeguard-gc.service" \
        || -e "${HOME}/.config/systemd/user/vibeguard-gc.timer" \
        || -L "${HOME}/.config/systemd/user/vibeguard-gc.timer" ]]
      ;;
    systemd)
      [[ -e "${HOME}/Library/LaunchAgents/com.vibeguard.gc.plist" \
        || -L "${HOME}/Library/LaunchAgents/com.vibeguard.gc.plist" ]]
      ;;
    *) return 1 ;;
  esac
}
scheduler_receipt_parse() {
  awk -F= '
    NR == 1 && $1 == "schema" && $2 == "1" { next }
    NR == 2 && $1 == "kind" && ($2 == "launchd" || $2 == "systemd") { kind = $2; next }
    NR == 3 && $1 == "phase" && ($2 == "managed" || $2 == "cleaning") {
      phase = $2
      declared_phase = 1
      next
    }
    NR == 3 && ((kind == "launchd" && $1 == "plist_sha256") || (kind == "systemd" && $1 == "service_sha256")) && $2 ~ /^[0-9a-f]{64}$/ {
      phase = "managed"
      first = $2
      next
    }
    NR == 4 && declared_phase && ((kind == "launchd" && $1 == "plist_sha256") || (kind == "systemd" && $1 == "service_sha256")) && $2 ~ /^[0-9a-f]{64}$/ {
      first = $2
      next
    }
    NR == 4 && !declared_phase && kind == "systemd" && $1 == "timer_sha256" && $2 ~ /^[0-9a-f]{64}$/ {
      second = $2
      next
    }
    NR == 5 && declared_phase && kind == "systemd" && $1 == "timer_sha256" && $2 ~ /^[0-9a-f]{64}$/ {
      second = $2
      next
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
scheduler_receipt_matches() {
  local expected_kind="${1:-${SCHEDULER_PLATFORM_KIND}}"
  local parsed kind phase first_sha second_sha actual_first actual_second
  local plist="${HOME}/Library/LaunchAgents/com.vibeguard.gc.plist"
  local service="${HOME}/.config/systemd/user/vibeguard-gc.service"
  local timer="${HOME}/.config/systemd/user/vibeguard-gc.timer"
  if [[ ! -e "${SCHEDULER_RECEIPT}" && ! -L "${SCHEDULER_RECEIPT}" ]]; then
    SCHEDULER_PRESERVE_REASON="scheduler ownership receipt is missing"
    return 1
  fi
  if [[ -L "${SCHEDULER_RECEIPT}" || ! -f "${SCHEDULER_RECEIPT}" ]]; then
    SCHEDULER_PRESERVE_REASON="scheduler ownership receipt is not a regular file"
    return 1
  fi
  if ! parsed="$(scheduler_receipt_parse "${SCHEDULER_RECEIPT}")"; then
    SCHEDULER_PRESERVE_REASON="scheduler ownership receipt is invalid"
    return 1
  fi
  IFS=$'\t' read -r kind phase first_sha second_sha <<< "${parsed}"
  if [[ "${kind}" != "${expected_kind}" ]]; then
    SCHEDULER_PRESERVE_REASON="scheduler ownership receipt kind ${kind} does not match ${SCHEDULER_PLATFORM} ${expected_kind} scheduler"
    return 1
  fi
  if [[ "${phase}" != "managed" ]]; then
    SCHEDULER_PRESERVE_REASON="scheduler ownership receipt is in cleaning phase; rerun setup --clean"
    return 1
  fi
  case "${kind}" in
    launchd)
      if [[ -L "${plist}" || ! -f "${plist}" ]] \
        || ! actual_first="$(setup_runtime_sha256_file "${plist}")" \
        || [[ "${actual_first}" != "${first_sha}" ]]; then
        SCHEDULER_PRESERVE_REASON="scheduler ownership receipt does not match current launchd file"
        return 1
      fi
      ;;
    systemd)
      if [[ -L "${service}" || ! -f "${service}" \
        || -L "${timer}" || ! -f "${timer}" ]] \
        || ! actual_first="$(setup_runtime_sha256_file "${service}")" \
        || ! actual_second="$(setup_runtime_sha256_file "${timer}")" \
        || [[ "${actual_first}" != "${first_sha}" || "${actual_second}" != "${second_sha}" ]]; then
        SCHEDULER_PRESERVE_REASON="scheduler ownership receipt does not match current systemd files"
        return 1
      fi
      ;;
  esac
  return 0
}
scheduler_receipt_preflight_for_mutation() {
  local expected_kind="$1" parsed kind phase
  if [[ ! -e "${SCHEDULER_RECEIPT}" && ! -L "${SCHEDULER_RECEIPT}" ]]; then
    :
  elif [[ -L "${SCHEDULER_RECEIPT}" || ! -f "${SCHEDULER_RECEIPT}" ]]; then
    red "ERROR: scheduler ownership receipt must be absent or a regular non-symlink file: ${SCHEDULER_RECEIPT}"
    return 1
  elif parsed="$(scheduler_receipt_parse "${SCHEDULER_RECEIPT}" 2>/dev/null)"; then
    IFS=$'\t' read -r kind phase _ <<< "${parsed}"
    if [[ "${kind}" != "${expected_kind}" ]]; then
      red "ERROR: scheduler ownership receipt kind ${kind} does not match ${SCHEDULER_PLATFORM} ${expected_kind} scheduler; preserving scheduler state."
      return 1
    fi
    if [[ "${phase}" == "cleaning" ]]; then
      red "ERROR: scheduler ownership receipt is in cleaning phase; rerun setup --clean before installing."
      return 1
    fi
  elif scheduler_files_exist; then
    red "ERROR: scheduler ownership receipt is invalid; preserving scheduler state."; return 1
  fi
  if scheduler_wrong_platform_files_exist "${expected_kind}"; then
    red "ERROR: wrong-platform scheduler files exist; preserving them and refusing to create a ${expected_kind} scheduler."
    return 1
  fi
}
write_scheduler_receipt() {
  local kind="$1" temporary first_sha second_sha=""
  local plist="${HOME}/Library/LaunchAgents/com.vibeguard.gc.plist"
  local service="${HOME}/.config/systemd/user/vibeguard-gc.service"
  local timer="${HOME}/.config/systemd/user/vibeguard-gc.timer"
  case "${kind}" in
    launchd)
      [[ -f "${plist}" && ! -L "${plist}" ]] || return 1
      first_sha="$(setup_runtime_sha256_file "${plist}")" || return 1
      ;;
    systemd)
      [[ -f "${service}" && ! -L "${service}" \
        && -f "${timer}" && ! -L "${timer}" ]] || return 1
      first_sha="$(setup_runtime_sha256_file "${service}")" || return 1
      second_sha="$(setup_runtime_sha256_file "${timer}")" || return 1
      ;;
    *) return 1 ;;
  esac
  mkdir -p "${VIBEGUARD_HOME}"
  temporary="$(mktemp "${VIBEGUARD_HOME}/.scheduler-ownership.XXXXXX")"
  if [[ "${kind}" == "launchd" ]]; then
    printf 'schema=1\nkind=launchd\nphase=managed\nplist_sha256=%s\n' \
      "${first_sha}" > "${temporary}"
  else
    printf 'schema=1\nkind=systemd\nphase=managed\nservice_sha256=%s\ntimer_sha256=%s\n' \
      "${first_sha}" "${second_sha}" > "${temporary}"
  fi
  chmod 600 "${temporary}"
  if ! mv -f -- "${temporary}" "${SCHEDULER_RECEIPT}"; then
    rm -f -- "${temporary}"
    return 1
  fi
  scheduler_receipt_matches "${kind}" || return 1
  state_record_file "${SCHEDULER_RECEIPT}" "generated/scheduler-ownership" "copy" \
    || return 1
}
if [[ "${WITH_SCHEDULER}" != "1" && "${VIBEGUARD_PAYLOAD_MODE:-0}" == "1" ]] \
  && scheduler_files_exist; then
  if [[ -z "${SCHEDULER_PLATFORM_KIND}" ]]; then
    SCHEDULER_PRESERVE_REASON="scheduler platform ${SCHEDULER_PLATFORM} is unsupported"
  elif scheduler_receipt_matches "${SCHEDULER_PLATFORM_KIND}"; then
    if scheduler_wrong_platform_files_exist "${SCHEDULER_PLATFORM_KIND}"; then
      SCHEDULER_PRESERVE_REASON="wrong-platform scheduler files do not match ${SCHEDULER_PLATFORM} ${SCHEDULER_PLATFORM_KIND} scheduler"
    else
      WITH_SCHEDULER=1
      SCHEDULER_REFRESHED=1
    fi
  fi
fi
# Check if a language is in the filter (empty filter = install all)
lang_selected() {
  local lang="$1"
  if [[ ${#LANG_FILTER[@]} -eq 0 ]]; then
    return 0  # no filter = all selected
  fi
  for l in "${LANG_FILTER[@]}"; do
    l="${l// /}"  # trim spaces
    # normalize: golang -> go in filter
    [[ "$l" == "golang" ]] && l="go"
    [[ "$lang" == "golang" ]] && lang="go"
    if [[ "$l" == "$lang" ]]; then
      return 0
    fi
  done
  return 1
}
validate_project_config_for_install() {
  local runtime_path="${1:-}" project_config_file project_config_out
  project_config_file="$(vg_project_config_file)"
  if [[ -z "${project_config_file}" || ! -f "${project_config_file}" ]]; then
    return 0
  fi
  if [[ -n "${runtime_path}" ]]; then
    project_config_out="$(VIBEGUARD_PROJECT_CONFIG_RUNTIME="${runtime_path}" vg_validate_project_config "${project_config_file}" 2>&1)" || {
      red "ERROR: invalid project config: ${project_config_file}"
      while IFS= read -r line; do
        red "  ${line}"
      done <<< "${project_config_out}"
      return 1
    }
  else
    project_config_out="$(vg_validate_project_config "${project_config_file}" 2>&1)" || {
      red "ERROR: invalid project config: ${project_config_file}"
      while IFS= read -r line; do
        red "  ${line}"
      done <<< "${project_config_out}"
      return 1
    }
  fi
  green "Project config valid: ${project_config_file}"
  echo
}
cleanup_install_temps() {
  if [[ -n "${_INSTALL_TMP:-}" ]]; then
    rm -rf "${_INSTALL_TMP}" 2>/dev/null || true
  fi
  if [[ -n "${_INSTALL_FINAL_TMP:-}" ]]; then
    rm -rf "${_INSTALL_FINAL_TMP}" 2>/dev/null || true
  fi
}
stage_install_snapshot() {
  if [[ -n "${_INSTALL_TMP}" ]]; then
    return 0
  fi
  _INSTALL_TMP="$(mktemp -d "${TMPDIR:-/tmp}/vibeguard-installed_tmp_XXXXXX")"
  trap cleanup_install_lifecycle EXIT
  cp -r "${REPO_DIR}/hooks" "${_INSTALL_TMP}/"
  cp -r "${REPO_DIR}/guards" "${_INSTALL_TMP}/"
  cp -r "${REPO_DIR}/rules" "${_INSTALL_TMP}/"
  cp -r "${REPO_DIR}/skills" "${_INSTALL_TMP}/"
  cp -r "${REPO_DIR}/workflows" "${_INSTALL_TMP}/"
  mkdir -p "${_INSTALL_TMP}/.claude"
  cp -r "${REPO_DIR}/.claude/commands" "${_INSTALL_TMP}/.claude/"
  mkdir -p "${_INSTALL_TMP}/schemas"
  cp "${REPO_DIR}/schemas/vibeguard-project.schema.json" "${_INSTALL_TMP}/schemas/"
  cp "${REPO_DIR}/schemas/vibeguard-runtime-config.schema.json" "${_INSTALL_TMP}/schemas/"
  if [[ "${VIBEGUARD_PAYLOAD_MODE:-0}" == "1" ]]; then
    payload_version="$(awk -F= '$1 == "version" { print $2; exit }' "${REPO_DIR}/.vibeguard-payload" 2>/dev/null || true)"
    printf 'payload-%s' "${payload_version:-unknown}" > "${_INSTALL_TMP}/version"
  else
    printf '%s' "$(git -C "${REPO_DIR}" rev-parse --short HEAD 2>/dev/null || echo 'unknown')" > "${_INSTALL_TMP}/version"
  fi
  # Runtime must be prepared before project config validation, but the staged
  # snapshot lives in TMPDIR until validation has passed.
  prepare_runtime_binary
  write_runtime_provenance_state "${_INSTALL_TMP}/runtime-provenance"
}
echo "=============================="
echo "VibeGuard Setup"
echo "Repository: ${REPO_DIR}"
echo "Profile: ${PROFILE}"
if [[ -n "$LANGUAGES" ]]; then
  echo "Languages: ${LANGUAGES}"
fi
if [[ "${VIBEGUARD_SETUP_DRY_RUN}" == "1" ]]; then
  echo "Mode: dry-run (high-context files are not written)"
fi
if [[ "${VIBEGUARD_SETUP_FORCE_OVERWRITE}" == "1" ]]; then
  echo "Mode: force-overwrite (user-customized managed files may be replaced)"
fi
if [[ "${BUILD_FROM_SOURCE}" == "1" ]]; then
  echo "Mode: build-from-source (vibeguard-runtime will be built with cargo)"
fi
if [[ "${REQUIRE_PROVENANCE}" == "1" ]]; then
  echo "Mode: require-provenance (release attestation must verify)"
fi
if [[ -n "${RUNTIME_VERSION_OVERRIDE}" ]]; then
  echo "Runtime version override: ${RUNTIME_VERSION_OVERRIDE}"
fi
if [[ "${WITH_SCHEDULER}" == "1" ]]; then
  if [[ "${SCHEDULER_REFRESHED}" == "1" ]]; then
    echo "Mode: refresh managed scheduler (preserve scheduler across payload updates)"
  else
    echo "Mode: with-scheduler (install launchd/systemd scheduled GC)"
  fi
fi
if [[ "${DEV_LINKED}" == "1" ]]; then
  echo "Mode: dev-linked repo (execution uses live repository paths)"
else
  echo "Mode: installed snapshot (execution uses ~/.vibeguard/installed)"
fi
echo "=============================="
echo
project_config_file="$(vg_project_config_file)"
if [[ -n "${project_config_file}" && -f "${project_config_file}" ]]; then
  stage_install_snapshot
  validate_project_config_for_install "${_INSTALL_TMP}/bin/vibeguard-runtime"
fi
if [[ "${VIBEGUARD_SETUP_DRY_RUN}" == "1" ]]; then
  stage_install_snapshot
  configure_claude_home_runtime
  inject_claude_home_rules
  inject_codex_home_rules
  yellow "Dry run complete. No files were written by setup.sh --dry-run."
  exit 0
fi
# Staging may precede this gate; active install mutation may not.
setup_preflight_and_lock || exit 1
# 1. Make sure the directory exists
echo "Step 1: Prepare directories"
mkdir -p "${CLAUDE_DIR}"
green "  ~/.claude/ ready"
#Write repo path + install hook wrapper (compatible with all platforms, no symlink dependencies)
mkdir -p "${VIBEGUARD_HOME}"
printf '%s' "${REPO_DIR}" > "${VIBEGUARD_HOME}/repo-path"
if [[ "${DEV_LINKED}" == "1" ]]; then
  printf '%s\n' "dev-linked-repo" > "${VIBEGUARD_HOME}/execution-mode"
else
  printf '%s\n' "installed-snapshot" > "${VIBEGUARD_HOME}/execution-mode"
fi
cp "${REPO_DIR}/hooks/run-hook.sh" "${VIBEGUARD_HOME}/run-hook.sh"
cp "${REPO_DIR}/hooks/run-hook-codex.sh" "${VIBEGUARD_HOME}/run-hook-codex.sh"
mkdir -p "${VIBEGUARD_HOME}/_lib"
cp "${REPO_DIR}/hooks/_lib/codex_diag.sh" "${VIBEGUARD_HOME}/_lib/codex_diag.sh"
cp "${REPO_DIR}/hooks/_lib/wrapper_env.sh" "${VIBEGUARD_HOME}/_lib/wrapper_env.sh"
chmod +x "${VIBEGUARD_HOME}/run-hook.sh" "${VIBEGUARD_HOME}/run-hook-codex.sh"
green "  ~/.vibeguard/repo-path + execution-mode + run-hook.sh + run-hook-codex.sh ready"
# Create user-rules directory for custom rules
mkdir -p "${VIBEGUARD_HOME}/user-rules"
green "  ~/.vibeguard/user-rules/ ready (add custom .md rules here)"
# Seed user config from example on first install. Existing user edits are
# preserved so setup re-runs do not overwrite tuned thresholds.
USER_CONFIG_FILE="${VIBEGUARD_HOME}/config.json"
USER_CONFIG_EXAMPLE="${REPO_DIR}/templates/vibeguard-config.json.example"
if [[ ! -f "${USER_CONFIG_FILE}" && -f "${USER_CONFIG_EXAMPLE}" ]]; then
  cp "${USER_CONFIG_EXAMPLE}" "${USER_CONFIG_FILE}"
  green "  ~/.vibeguard/config.json seeded (edit to tune write_mode and thresholds)"
elif [[ -f "${USER_CONFIG_FILE}" ]]; then
  green "  ~/.vibeguard/config.json present (preserved)"
fi
# Install hooks and guards snapshot (isolated from dev repo — prevents dirty state from breaking hooks)
# Atomic install: copy to temp dir, then rename into place. If interrupted mid-copy,
# the previous installed/ remains intact instead of being left empty.
INSTALLED_DIR="${VIBEGUARD_HOME}/installed"
stage_install_snapshot
_INSTALL_FINAL_TMP="$(mktemp -d "${VIBEGUARD_HOME}/installed_tmp_XXXXXX")"
cp -R "${_INSTALL_TMP}/." "${_INSTALL_FINAL_TMP}/"
# Swap: move old installed aside, rename new into place, restore on failure
if [[ -d "${INSTALLED_DIR}" ]]; then
  mv "${INSTALLED_DIR}" "${INSTALLED_DIR}.old.$$"
fi
if mv "${_INSTALL_FINAL_TMP}" "${INSTALLED_DIR}"; then
  _INSTALL_FINAL_TMP=""
  rm -rf "${INSTALLED_DIR}.old.$$" 2>/dev/null || true
else
  # Restore old snapshot if swap failed
  if [[ -d "${INSTALLED_DIR}.old.$$" ]]; then
    mv "${INSTALLED_DIR}.old.$$" "${INSTALLED_DIR}" 2>/dev/null || true
  fi
  red "  Failed to install snapshot (old version restored)"
  exit 1
fi
rm -rf "${_INSTALL_TMP}" 2>/dev/null || true
_INSTALL_TMP=""
trap cleanup_install_lifecycle EXIT
green "  ~/.vibeguard/installed/ hooks+guards snapshot ($(cat "${INSTALLED_DIR}/version"))"
if [[ -f "${INSTALLED_DIR}/runtime-provenance" ]]; then
  runtime_provenance_status="$(awk -F= '$1 == "status" { print $2; exit }' "${INSTALLED_DIR}/runtime-provenance")"
  runtime_provenance_reason="$(awk -F= '$1 == "reason" { print $2; exit }' "${INSTALLED_DIR}/runtime-provenance")"
  case "${runtime_provenance_status}" in
    verified-provenance)
      green "  runtime provenance status: verified-provenance"
      ;;
    checksum-only)
      yellow "  runtime provenance status: checksum-only (${runtime_provenance_reason:-verifier unavailable})"
      ;;
    source-build)
      yellow "  runtime provenance status: source-build (${runtime_provenance_reason:-local build})"
      ;;
    *)
      yellow "  runtime provenance status: ${runtime_provenance_status:-unknown}"
      ;;
  esac
fi
if [[ "${VIBEGUARD_SETUP_DRY_RUN}" != "1" ]]; then
  echo "Step 1.5: Clean retired skill links"
  cleanup_retired_manifest_skill_links "~/.claude/skills/" "${CLAUDE_DIR}/skills"
  cleanup_retired_manifest_skill_links "~/.codex/skills/" "${CODEX_DIR}/skills"
  echo
fi
# Initialize install state tracking
state_init "$PROFILE" "$LANGUAGES"
state_record_tree "${INSTALLED_DIR}" "installed"
state_record_file "${VIBEGUARD_HOME}/repo-path" "generated/repo-path" "copy"
state_record_file "${VIBEGUARD_HOME}/execution-mode" "generated/execution-mode" "copy"
state_record_file "${VIBEGUARD_HOME}/run-hook.sh" "hooks/run-hook.sh" "copy"
state_record_file "${VIBEGUARD_HOME}/_lib/codex_diag.sh" "hooks/_lib/codex_diag.sh" "copy"
state_record_file "${VIBEGUARD_HOME}/_lib/wrapper_env.sh" "hooks/_lib/wrapper_env.sh" "copy"
green "  Install state tracker initialized"
echo
install_claude_home_assets

install_codex_home_assets

# 7. Detect auto-run-agent environment variable
echo "Step 7: Check auto-run-agent"
if [[ -n "${AUTO_RUN_AGENT_DIR:-}" ]] && [[ -d "${AUTO_RUN_AGENT_DIR}" ]]; then
  green "  AUTO_RUN_AGENT_DIR=${AUTO_RUN_AGENT_DIR}"
else
  yellow "  AUTO_RUN_AGENT_DIR not set (optional, needed for auto-optimize Phase 4)"
fi
echo

configure_claude_home_runtime

# 9.5. Scheduled GC is opt-in. Default setup must not create launchd/systemd jobs.
echo "Step 9.5: Scheduled GC"
if [[ "${WITH_SCHEDULER}" != "1" ]]; then
  if [[ -n "${SCHEDULER_PRESERVE_REASON}" ]]; then
    yellow "  ${SCHEDULER_PRESERVE_REASON}; preserving scheduler files (replace explicitly: bash setup.sh --yes --with-scheduler)"
  else
    yellow "  Scheduled GC not installed by default (opt in: bash setup.sh --yes --with-scheduler)"
  fi
  echo "  On-demand GC: /vibeguard:gc or bash scripts/gc/gc-scheduled.sh"
elif [[ "${SCHEDULER_PLATFORM}" == "Darwin" ]]; then
  scheduler_receipt_preflight_for_mutation launchd || exit 1
  chmod +x "${SCHEDULER_REPO_DIR}/scripts/gc/gc-scheduled.sh"
  PLIST_SRC="${SCRIPT_DIR}/com.vibeguard.gc.plist"
  PLIST_DEST="${HOME}/Library/LaunchAgents/com.vibeguard.gc.plist"
  PLIST_BACKUP="" PLIST_STAGED="" RECEIPT_BACKUP=""
  if [[ -f "${PLIST_SRC}" ]]; then
    if [[ -L "${PLIST_DEST}" || (-e "${PLIST_DEST}" && ! -f "${PLIST_DEST}") ]]; then
      red "ERROR: scheduled GC plist destination must be a regular file or absent: ${PLIST_DEST}"
      exit 1
    fi
    mkdir -p "${HOME}/Library/LaunchAgents"
    if [[ "${SCHEDULER_REFRESHED}" == "1" ]]; then
      PLIST_BACKUP="$(mktemp "${HOME}/Library/LaunchAgents/.com.vibeguard.gc.plist.XXXXXX")"
      RECEIPT_BACKUP="$(mktemp "${VIBEGUARD_HOME}/.scheduler-ownership-refresh.XXXXXX")"
      cp -p -- "${PLIST_DEST}" "${PLIST_BACKUP}"
      cp -p -- "${SCHEDULER_RECEIPT}" "${RECEIPT_BACKUP}"
    fi
    PLIST_STAGED="$(mktemp "${HOME}/Library/LaunchAgents/.com.vibeguard.gc.plist.staged.XXXXXX")"
    if ! sed -e "s|__VIBEGUARD_DIR__|${SCHEDULER_REPO_DIR}|g" \
      -e "s|__HOME__|${HOME}|g" "${PLIST_SRC}" > "${PLIST_STAGED}"; then
      rm -f -- "${PLIST_STAGED}"
      [[ -z "${PLIST_BACKUP}" ]] || rm -f -- "${PLIST_BACKUP}" "${RECEIPT_BACKUP}"
      red "ERROR: failed to stage scheduled GC launchd plist."
      exit 1
    fi
    chmod 644 "${PLIST_STAGED}"
    if launchctl print "gui/$(id -u)/com.vibeguard.gc" >/dev/null 2>&1 \
      && ! launchctl bootout "gui/$(id -u)/com.vibeguard.gc" >/dev/null 2>&1; then
      rm -f -- "${PLIST_STAGED}"
      [[ -z "${PLIST_BACKUP}" ]] || rm -f -- "${PLIST_BACKUP}" "${RECEIPT_BACKUP}"
      red "ERROR: failed to deactivate managed launchd scheduler before refresh."
      exit 1
    fi
    mv -f -- "${PLIST_STAGED}" "${PLIST_DEST}"
    if launchctl bootstrap "gui/$(id -u)" "${PLIST_DEST}" 2>/dev/null; then
      write_scheduler_receipt launchd || {
        if [[ -n "${PLIST_BACKUP}" ]]; then
          launchctl bootout "gui/$(id -u)/com.vibeguard.gc" >/dev/null 2>&1 || true
          mv -f -- "${PLIST_BACKUP}" "${PLIST_DEST}"
          mv -f -- "${RECEIPT_BACKUP}" "${SCHEDULER_RECEIPT}"
          launchctl bootstrap "gui/$(id -u)" "${PLIST_DEST}" >/dev/null 2>&1 || true
        fi
        red "ERROR: failed to record launchd scheduler ownership."
        exit 1
      }
      if [[ -n "${PLIST_BACKUP}" ]]; then
        rm -f -- "${PLIST_BACKUP}" "${RECEIPT_BACKUP}"
      fi
      green "  Scheduled GC installed via launchd (every Sunday 3:00 AM)"
    else
      if [[ -n "${PLIST_BACKUP}" ]]; then
        mv -f -- "${PLIST_BACKUP}" "${PLIST_DEST}"
        mv -f -- "${RECEIPT_BACKUP}" "${SCHEDULER_RECEIPT}"
        if ! launchctl bootstrap "gui/$(id -u)" "${PLIST_DEST}" >/dev/null 2>&1; then
          red "ERROR: failed to reload the previous managed launchd scheduler; retry setup to recover."
        fi
      fi
      red "ERROR: Scheduled GC plist installed but bootstrap failed (try: launchctl load ${PLIST_DEST})"
      exit 1
    fi
  else
    red "ERROR: scheduled GC plist not found: ${PLIST_SRC}"
    exit 1
  fi
elif [[ "${SCHEDULER_PLATFORM}" == "Linux" ]] && command -v systemctl &>/dev/null; then
  scheduler_receipt_preflight_for_mutation systemd || exit 1
  chmod +x "${SCHEDULER_REPO_DIR}/scripts/gc/gc-scheduled.sh"
  if VIBEGUARD_REPO_DIR="${SCHEDULER_REPO_DIR}" \
    bash "${REPO_DIR}/scripts/install-systemd.sh"; then
    write_scheduler_receipt systemd || {
      red "ERROR: failed to record systemd scheduler ownership."
      exit 1
    }
    green "  Scheduled GC installed via systemd (every Sunday 3:00 AM)"
  else
    red "ERROR: Scheduled GC systemd install failed (run: bash scripts/install-systemd.sh)"
    exit 1
  fi
else
  red "ERROR: --with-scheduler requires macOS launchd or Linux systemd"
  exit 1
fi
echo

# 9.7. Install git hook wrappers
echo "Step 9.7: Install git hooks"
PRE_COMMIT_WRAPPER="${VIBEGUARD_HOME}/pre-commit"
cat > "${PRE_COMMIT_WRAPPER}" <<'WRAPPER'
#!/usr/bin/env bash
# VibeGuard Pre-Commit Hook Wrapper — auto-installed by setup.sh
set -euo pipefail
mode="$(tr -d '[:space:]' < "$HOME/.vibeguard/execution-mode" 2>/dev/null || true)"
case "$mode" in
  dev-linked|dev-linked-repo|repo|repo-linked)
    VIBEGUARD_DIR="$(cat "$HOME/.vibeguard/repo-path" 2>/dev/null)" || true
    ;;
  *)
    VIBEGUARD_DIR="$HOME/.vibeguard/installed"
    ;;
esac
if [[ -n "$VIBEGUARD_DIR" ]] && [[ -f "$VIBEGUARD_DIR/hooks/pre-commit-guard.sh" ]]; then
  export VIBEGUARD_DIR
  exec bash "$VIBEGUARD_DIR/hooks/pre-commit-guard.sh"
fi
echo "vibeguard: pre-commit hook source not found for execution mode '${mode:-installed-snapshot}'; re-run bash setup.sh --yes" >&2
exit 1
WRAPPER
chmod +x "${PRE_COMMIT_WRAPPER}"
state_record_file "${PRE_COMMIT_WRAPPER}" "generated/pre-commit-wrapper" "copy"
green "  ~/.vibeguard/pre-commit wrapper ready"

PRE_PUSH_WRAPPER="${VIBEGUARD_HOME}/pre-push"
cat > "${PRE_PUSH_WRAPPER}" <<'WRAPPER'
#!/usr/bin/env bash
# VibeGuard Pre-Push Hook Wrapper — auto-installed by setup.sh
set -euo pipefail
mode="$(tr -d '[:space:]' < "$HOME/.vibeguard/execution-mode" 2>/dev/null || true)"
case "$mode" in
  dev-linked|dev-linked-repo|repo|repo-linked)
    VIBEGUARD_DIR="$(cat "$HOME/.vibeguard/repo-path" 2>/dev/null)" || true
    ;;
  *)
    VIBEGUARD_DIR="$HOME/.vibeguard/installed"
    ;;
esac
if [[ -n "$VIBEGUARD_DIR" ]] && [[ -f "$VIBEGUARD_DIR/hooks/git/pre-push" ]]; then
  export VIBEGUARD_DIR
  exec bash "$VIBEGUARD_DIR/hooks/git/pre-push" "$@"
fi
echo "vibeguard: pre-push hook source not found for execution mode '${mode:-installed-snapshot}'; re-run bash setup.sh --yes" >&2
exit 1
WRAPPER
chmod +x "${PRE_PUSH_WRAPPER}"
state_record_file "${PRE_PUSH_WRAPPER}" "generated/pre-push-wrapper" "copy"
green "  ~/.vibeguard/pre-push wrapper ready"

install_repo_git_hook() {
  local hook_name="$1"
  local target="$2"
  local hook_path="${VG_GIT_HOOKS}/${hook_name}"

  if [[ -e "${hook_path}" && ! -L "${hook_path}" ]]; then
    red "  ERROR: ${hook_path} already exists and is not a symlink; refusing to overwrite"
    return 1
  fi
  rm -f "${hook_path}"
  ln -s "${target}" "${hook_path}"
  if [[ "$(readlink "${hook_path}" 2>/dev/null || true)" != "${target}" ]]; then
    red "  ERROR: failed to install ${hook_name} hook at ${hook_path}"
    return 1
  fi
  state_record_project_hook "${REPO_DIR}" "${hook_path}" "${hook_name}"
  green "  ${hook_name} hook installed to vibeguard repo"
}
if [[ "${VIBEGUARD_PAYLOAD_MODE:-0}" == "1" ]]; then
  yellow "  SKIP repo git hooks (payload mode)"
elif VG_GIT_TOP="$(git -C "${REPO_DIR}" rev-parse --show-toplevel 2>/dev/null)" \
  && VG_REPO_PHYSICAL="$(cd "${REPO_DIR}" && pwd -P)" \
  && [[ "${VG_GIT_TOP}" == "${VG_REPO_PHYSICAL}" ]] \
  && VG_GIT_HOOKS="$(git -C "${REPO_DIR}" rev-parse --path-format=absolute --git-path hooks 2>/dev/null)"; then
  mkdir -p "${VG_GIT_HOOKS}"
  install_repo_git_hook "pre-commit" "${PRE_COMMIT_WRAPPER}"
  install_repo_git_hook "pre-push" "${PRE_PUSH_WRAPPER}"
else
  yellow "  SKIP repo git hooks (not an exact git repository root)"
fi
echo
inject_claude_home_rules
inject_codex_home_rules

# 11. Verification
echo "Step 11: Verification"
echo "=============================="
if ! bash "${SCRIPT_DIR}/check.sh" --install; then
  red "ERROR: strict install verification failed. Run 'bash setup.sh --check --install' for details."
  exit 2
fi
echo
green "Setup complete! All components installed."
echo
echo "Next steps:"
echo "  1. Open a new Claude Code session to verify rules are active"
echo "  2. Switch profile: bash setup.sh --profile minimal|core|full|strict"
echo "  3. Run: /vibeguard:preflight <project_dir>"
echo "  4. Run: /vibeguard:check <project_dir>"
echo
echo "Project policy configuration (.vibeguard.json or env vars):"
echo "  VIBEGUARD_PROFILE=minimal|core|full|strict   Project policy profile"
echo "  VIBEGUARD_ENFORCEMENT=block|warn|off          Project policy enforcement level"
echo "  VIBEGUARD_DISABLED_HOOKS=hook1,hook2           Disable project hooks"
echo "  VIBEGUARD_GC_*                                 Project GC thresholds; see schemas/vibeguard-project.schema.json"
echo
echo "User runtime tuning (~/.vibeguard/config.json or env vars):"
printf '%s\n' "  VIBEGUARD_WRITE_MODE=warn|block                New-source write guard mode" "  VG_U16_WARN_LIMIT / VG_U16_LIMIT               U-16 advisory and hard limits" "  VIBEGUARD_DISABLED_SKILLS=plan-flow,fixflow     Temporary Codex managed-skill override"
echo
printf '%s\n' "Git Hooks:" "Automatically installed to VibeGuard repository (pre-commit + pre-push)" "Other projects: bash scripts/project-init.sh <project_dir>"
setup_lock_release

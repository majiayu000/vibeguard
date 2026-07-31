#!/usr/bin/env bash
# Install one exact VibeGuard payload release without a repository clone.
#
# Usage:
#   bash bootstrap.sh --version X.Y.Z [--require-provenance] [-- SETUP_ARGS...]

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_LIB="${SCRIPT_DIR}/bootstrap-lib.sh"
if [[ ! -f "${BOOTSTRAP_LIB}" ]]; then
  printf 'ERROR: missing bootstrap helper: %s\n' "${BOOTSTRAP_LIB}" >&2
  exit 1
fi
# shellcheck source=scripts/setup/bootstrap-lib.sh
source "${BOOTSTRAP_LIB}"

RELEASE_REPO="majiayu000/vibeguard"
VERSION=""
VERSION_SET=0
REQUIRE_PROVENANCE=0
declare -a SETUP_ARGS=()
SETUP_ARG_COUNT=0
CLEAN_REQUESTED=0
CLEAN_HELP_REQUESTED=0

bootstrap_usage() {
  printf '%s\n' \
    "Usage: bash bootstrap.sh --version X.Y.Z [--require-provenance] [-- SETUP_ARGS...]" \
    "" \
    "Downloads an exact VibeGuard payload release, verifies it, and runs its setup.sh." \
    "Remote content is never piped into a shell."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || {
        bootstrap_error "--version requires an exact X.Y.Z value."
        exit 64
      }
      [[ "${VERSION_SET}" == "0" ]] || {
        bootstrap_error "--version may be provided only once."
        exit 64
      }
      VERSION="${2#v}"
      VERSION_SET=1
      shift 2
      ;;
    --version=*)
      [[ "${VERSION_SET}" == "0" ]] || {
        bootstrap_error "--version may be provided only once."
        exit 64
      }
      VERSION="${1#*=}"
      VERSION="${VERSION#v}"
      VERSION_SET=1
      shift
      ;;
    --require-provenance)
      [[ "${REQUIRE_PROVENANCE}" == "0" ]] || {
        bootstrap_error "--require-provenance may be provided only once."
        exit 64
      }
      REQUIRE_PROVENANCE=1
      shift
      ;;
    --help|-h)
      bootstrap_usage
      exit 0
      ;;
    --)
      shift
      SETUP_ARGS=("$@")
      SETUP_ARG_COUNT=$#
      break
      ;;
    *)
      bootstrap_error "unknown bootstrap argument: $1"
      bootstrap_usage >&2
      exit 64
      ;;
  esac
done

if [[ "${VERSION_SET}" != "1" || -z "${VERSION}" ]]; then
  bootstrap_error "--version is required; latest and floating release selection are forbidden."
  exit 64
fi
if ! bootstrap_validate_version "${VERSION}"; then
  bootstrap_error "invalid exact version: ${VERSION} (expected X.Y.Z or an exact semver prerelease)."
  exit 64
fi
if [[ "${SETUP_ARGS[0]:-}" == "--clean" ]]; then
  CLEAN_REQUESTED=1
  if bootstrap_setup_args_include_help; then
    CLEAN_HELP_REQUESTED=1
  fi
fi
if [[ -z "${HOME:-}" || "${HOME}" != /* ]]; then
  bootstrap_error "HOME must be a non-empty absolute path."
  exit 1
fi
if ! command -v tar >/dev/null 2>&1; then
  bootstrap_error "tar is required to inspect and extract the payload."
  exit 1
fi

VIBEGUARD_HOME="${HOME}/.vibeguard"
DIST_ROOT="${VIBEGUARD_HOME}/dist"
FINAL_DIR="${DIST_ROOT}/${VERSION}"
CURRENT_LINK="${DIST_ROOT}/current"
LOCK_DIR="${DIST_ROOT}/.bootstrap.lock"
TRANSACTION_FILE="${DIST_ROOT}/.bootstrap-transaction-${VERSION}"
BOOTSTRAP_TMP=""
LOCK_OWNER_TMP=""
LOCK_HELD=0
FINAL_DIR_OWNED=0
TRANSACTION_OWNED=0
SETUP_STARTED=0
PREVIOUS_CURRENT_PRESENT=0
PREVIOUS_CURRENT_TARGET=""
CURRENT_SWITCHED=0
TRANSACTION_COMMITTED=0
LOCK_OWNER_PID=""
LOCK_OWNER_NONCE=""
BOOTSTRAP_SETUP_LEASE_FILE=""
BOOTSTRAP_SETUP_LEASE_HELD=0
bootstrap_reap_existing_lock() {
  local legacy_owner

  if [[ -L "${LOCK_DIR}" ]]; then
    bootstrap_error "bootstrap lock must not be a symlink: ${LOCK_DIR}"
    return 73
  fi
  if [[ -d "${LOCK_DIR}" ]]; then
    legacy_owner="${LOCK_DIR}/owner"
    if ! bootstrap_lock_parse_owner_file "${legacy_owner}"; then
      bootstrap_error "legacy lock inactivity cannot be proven; preserving ${LOCK_DIR}."
      return 73
    fi
    bootstrap_pid_liveness "${BOOTSTRAP_LOCK_READ_PID}"
    case "${BOOTSTRAP_PID_LIVENESS}" in
      active)
        bootstrap_error "active bootstrap owner pid=${BOOTSTRAP_LOCK_READ_PID} holds ${LOCK_DIR}."
        return 73
        ;;
      dead) ;;
      *)
        bootstrap_error "cannot prove lock owner pid=${BOOTSTRAP_LOCK_READ_PID} is dead; preserving ${LOCK_DIR}."
        return 73
        ;;
    esac
    bootstrap_lock_reap_legacy_directory \
      "${LOCK_DIR}" "${DIST_ROOT}" \
      "${BOOTSTRAP_LOCK_READ_PID}" "${BOOTSTRAP_LOCK_READ_NONCE}" \
      "legacy-lock recovery" || return 73
    return 0
  fi
  if [[ ! -f "${LOCK_DIR}" ]] || ! bootstrap_lock_parse_owner_file "${LOCK_DIR}"; then
    return 73
  fi
  bootstrap_pid_liveness "${BOOTSTRAP_LOCK_READ_PID}"
  case "${BOOTSTRAP_PID_LIVENESS}" in
    active)
      bootstrap_error "active bootstrap owner pid=${BOOTSTRAP_LOCK_READ_PID} holds ${LOCK_DIR}."
      return 73
      ;;
    dead) ;;
    *)
      bootstrap_error "cannot prove lock owner pid=${BOOTSTRAP_LOCK_READ_PID} is dead; preserving ${LOCK_DIR}."
      return 73
      ;;
  esac
  bootstrap_setup_lease_clear_inactive \
    "${DIST_ROOT}/.bootstrap.lock.lease.${BOOTSTRAP_LOCK_READ_NONCE}" \
    "${BOOTSTRAP_LOCK_READ_PID}" "${BOOTSTRAP_LOCK_READ_NONCE}" || return 73
  bootstrap_lock_reap_exact_owner \
    "${LOCK_DIR}" "${DIST_ROOT}" \
    "${BOOTSTRAP_LOCK_READ_PID}" "${BOOTSTRAP_LOCK_READ_NONCE}" \
    "stale-lock recovery" "1" || return 73
}

bootstrap_acquire_owner_lock() {
  local attempt lock_rc nested_owner

  for attempt in 1 2 3; do
    if [[ -e "${LOCK_DIR}" || -L "${LOCK_DIR}" ]]; then
      lock_rc=0
      bootstrap_reap_existing_lock || lock_rc=$?
      [[ "${lock_rc}" -eq 0 ]] || return "${lock_rc}"
      continue
    fi

    LOCK_OWNER_PID="$$"
    LOCK_OWNER_NONCE="$$-${RANDOM}-${attempt}"
    LOCK_OWNER_TMP="${DIST_ROOT}/.bootstrap.lock.owner.${LOCK_OWNER_NONCE}"
    if [[ -e "${LOCK_OWNER_TMP}" || -L "${LOCK_OWNER_TMP}" ]]; then
      bootstrap_error "bootstrap lock owner temporary path exists: ${LOCK_OWNER_TMP}"
      return 1
    fi
    if ! printf 'pid=%s\nnonce=%s\n' "${LOCK_OWNER_PID}" "${LOCK_OWNER_NONCE}" \
      > "${LOCK_OWNER_TMP}"; then
      bootstrap_error "could not initialize bootstrap lock owner metadata."
      return 1
    fi
    if ln "${LOCK_OWNER_TMP}" "${LOCK_DIR}" 2>/dev/null; then
      if [[ ! -L "${LOCK_DIR}" && -f "${LOCK_DIR}" \
        && "${LOCK_DIR}" -ef "${LOCK_OWNER_TMP}" ]]; then
        rm -f -- "${LOCK_OWNER_TMP}"
        LOCK_OWNER_TMP=""
        LOCK_HELD=1
        return 0
      fi
      nested_owner="${LOCK_DIR}/${LOCK_OWNER_TMP##*/}"
      if [[ -d "${LOCK_DIR}" && -f "${nested_owner}" \
        && "${nested_owner}" -ef "${LOCK_OWNER_TMP}" ]]; then
        rm -f -- "${nested_owner}"
      fi
      rm -f -- "${LOCK_OWNER_TMP}"
      LOCK_OWNER_TMP=""
      bootstrap_error "bootstrap lock path changed type during atomic publish."
      return 73
    fi
    rm -f -- "${LOCK_OWNER_TMP}"
    LOCK_OWNER_TMP=""
    if [[ ! -e "${LOCK_DIR}" && ! -L "${LOCK_DIR}" ]]; then
      bootstrap_error "atomic bootstrap lock publish failed without a competing owner."
      return 1
    fi
    lock_rc=0
    bootstrap_reap_existing_lock || lock_rc=$?
    [[ "${lock_rc}" -eq 0 ]] || return "${lock_rc}"
  done

  bootstrap_error "could not acquire bootstrap lock after stale-owner recovery."
  return 73
}

bootstrap_release_owner_lock() {
  if ! bootstrap_lock_reap_exact_owner \
    "${LOCK_DIR}" "${DIST_ROOT}" "${LOCK_OWNER_PID}" "${LOCK_OWNER_NONCE}" \
    "lock release"; then
    return 1
  fi
  LOCK_HELD=0
}

bootstrap_restore_previous_current() {
  local rollback_link

  [[ "${CURRENT_SWITCHED}" == "1" ]] || return 0
  if [[ ! -L "${CURRENT_LINK}" || "$(readlink "${CURRENT_LINK}")" != "${VERSION}" ]]; then
    bootstrap_error "current changed unexpectedly; refusing unsafe bootstrap rollback."
    return 1
  fi

  if [[ "${PREVIOUS_CURRENT_PRESENT}" == "1" ]]; then
    rollback_link="${BOOTSTRAP_TMP}/previous-current-link"
    if [[ -e "${rollback_link}" || -L "${rollback_link}" ]]; then
      bootstrap_error "bootstrap rollback link path already exists: ${rollback_link}"
      return 1
    fi
    if ! ln -s -- "${PREVIOUS_CURRENT_TARGET}" "${rollback_link}" \
      || ! bootstrap_atomic_replace_symlink "${rollback_link}" "${CURRENT_LINK}" \
      || [[ ! -L "${CURRENT_LINK}" ]] \
      || [[ "$(readlink "${CURRENT_LINK}")" != "${PREVIOUS_CURRENT_TARGET}" ]]; then
      bootstrap_error "failed to roll back dist/current to its previous symlink target."
      return 1
    fi
  else
    if ! rm -f -- "${CURRENT_LINK}" \
      || [[ -e "${CURRENT_LINK}" || -L "${CURRENT_LINK}" ]]; then
      bootstrap_error "failed to roll back dist/current to its previous absent state."
      return 1
    fi
  fi

  CURRENT_SWITCHED=0
  return 0
}

bootstrap_cleanup() {
  local status=$?
  if [[ "${BOOTSTRAP_SETUP_LEASE_HELD}" == "1" ]]; then
    if ! bootstrap_setup_lease_clear_inactive "${BOOTSTRAP_SETUP_LEASE_FILE}" \
      "${LOCK_OWNER_PID}" "${LOCK_OWNER_NONCE}"; then
      bootstrap_error "active setup lease prevents unsafe bootstrap cleanup."
      return 1
    fi
    BOOTSTRAP_SETUP_LEASE_HELD=0
    BOOTSTRAP_SETUP_LEASE_FILE=""
  fi
  if [[ -n "${LOCK_OWNER_TMP}" ]]; then
    rm -f -- "${LOCK_OWNER_TMP}" 2>/dev/null || status=1
  fi
  if [[ "${SETUP_STARTED}" == "0" && "${TRANSACTION_COMMITTED}" == "0" \
    && "${CURRENT_SWITCHED}" == "1" ]]; then
    if ! bootstrap_restore_previous_current; then
      status=1
    fi
  fi
  if [[ "${FINAL_DIR_OWNED}" == "1" && "${SETUP_STARTED}" == "0" \
    && "${TRANSACTION_COMMITTED}" == "0" \
    && "${CURRENT_SWITCHED}" == "0" ]]; then
    if ! rm -rf -- "${FINAL_DIR}"; then
      bootstrap_error "failed to remove newly owned distribution after bootstrap failure: ${FINAL_DIR}"
      status=1
    fi
  elif [[ "${FINAL_DIR_OWNED}" == "1" && "${SETUP_STARTED}" == "0" \
    && "${TRANSACTION_COMMITTED}" == "0" ]]; then
    bootstrap_error "rollback incomplete; retaining current-referenced distribution evidence: ${FINAL_DIR}"
    status=1
  fi
  if [[ "${TRANSACTION_OWNED}" == "1" && "${SETUP_STARTED}" == "0" \
    && "${TRANSACTION_COMMITTED}" == "0" ]]; then
    if ! rm -f -- "${TRANSACTION_FILE}"; then
      bootstrap_error "failed to remove uncommitted bootstrap transaction: ${TRANSACTION_FILE}"
      status=1
    fi
  fi
  if [[ -n "${BOOTSTRAP_TMP}" && "${BOOTSTRAP_TMP}" == "${DIST_ROOT}/.bootstrap-${VERSION}."* ]]; then
    if ! rm -rf -- "${BOOTSTRAP_TMP}"; then
      bootstrap_error "failed to remove bootstrap temporary directory: ${BOOTSTRAP_TMP}"
      status=1
    fi
  fi
  if [[ "${LOCK_HELD}" == "1" ]]; then
    if ! bootstrap_release_owner_lock; then
      bootstrap_error "failed to release bootstrap lock: ${LOCK_DIR}"
      status=1
    fi
  fi
  return "${status}"
}

bootstrap_run_setup_script() {
  bootstrap_run_setup_with_lease "$1" "${DIST_ROOT}" \
    "${LOCK_OWNER_PID}" "${LOCK_OWNER_NONCE}" "${SETUP_ARGS[@]}"
}

bootstrap_finish_cleanup() {
  local cleanup_rc=0
  trap - EXIT
  bootstrap_cleanup || cleanup_rc=$?
  return "${cleanup_rc}"
}
trap bootstrap_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [[ -L "${VIBEGUARD_HOME}" || (-e "${VIBEGUARD_HOME}" && ! -d "${VIBEGUARD_HOME}") ]]; then
  bootstrap_error "${VIBEGUARD_HOME} must be a real directory, not a link or file."
  exit 1
fi
mkdir -p "${VIBEGUARD_HOME}"
if [[ -L "${DIST_ROOT}" || (-e "${DIST_ROOT}" && ! -d "${DIST_ROOT}") ]]; then
  bootstrap_error "${DIST_ROOT} must be a real directory, not a link or file."
  exit 1
fi
mkdir -p "${DIST_ROOT}"
lock_rc=0
bootstrap_acquire_owner_lock || lock_rc=$?
if [[ "${lock_rc}" -ne 0 ]]; then
  exit "${lock_rc}"
fi
# Holding the single bootstrap owner lock proves no live transaction can own
# a canonical work directory left by an earlier SIGKILL or power loss.
bootstrap_reap_orphaned_work_directories "${DIST_ROOT}" || exit 73

if [[ -e "${CURRENT_LINK}" && ! -L "${CURRENT_LINK}" ]]; then
  bootstrap_error "dist/current exists and is not a symlink; refusing to overwrite it."
  exit 73
fi
if [[ -e "${TRANSACTION_FILE}" || -L "${TRANSACTION_FILE}" ]]; then
  if ! bootstrap_transaction_read "${TRANSACTION_FILE}" \
    || [[ "${BOOTSTRAP_TRANSACTION_VERSION}" != "${VERSION}" ]]; then
    bootstrap_error "existing distribution has no valid repair transaction: ${FINAL_DIR}"
    exit 73
  fi
  if [[ "${BOOTSTRAP_TRANSACTION_PHASE}" == "cleaning" \
    && "${CLEAN_REQUESTED}" != "1" ]]; then
    bootstrap_error "bootstrap clean transaction is incomplete; rerun the same --clean command."
    exit 73
  fi
elif [[ -e "${FINAL_DIR}" || -L "${FINAL_DIR}" ]]; then
  bootstrap_error "distribution version already exists without repair evidence: ${FINAL_DIR}"
  exit 73
fi

BOOTSTRAP_TMP="$(mktemp -d "${DIST_ROOT}/.bootstrap-${VERSION}.XXXXXX")"
DOWNLOAD_ROOT="${BOOTSTRAP_TMP}/download"
STAGE_DIR="${BOOTSTRAP_TMP}/stage"
NAMES_FILE="${BOOTSTRAP_TMP}/archive-names"
TYPES_FILE="${BOOTSTRAP_TMP}/archive-types"
mkdir -p "${DOWNLOAD_ROOT}" "${STAGE_DIR}"

TAG="v${VERSION}"
ASSET="vibeguard-payload-${VERSION}.tar.gz"
printf 'Downloading %s from %s@%s...\n' "${ASSET}" "${RELEASE_REPO}" "${TAG}"
DOWNLOAD_DIR="$(
  bootstrap_download_release_assets \
    "${RELEASE_REPO}" "${TAG}" "${ASSET}" "${DOWNLOAD_ROOT}"
)"
ARCHIVE="${DOWNLOAD_DIR}/${ASSET}"
SUMS="${DOWNLOAD_DIR}/SHA256SUMS"

bootstrap_verify_checksum "${ARCHIVE}" "${SUMS}" "${ASSET}"
provenance_rc=0
bootstrap_verify_release_provenance "${ARCHIVE}" "${RELEASE_REPO}" "${TAG}" \
  || provenance_rc=$?
case "${provenance_rc}" in
  0)
    ;;
  2)
    if [[ "${REQUIRE_PROVENANCE}" == "1" ]]; then
      bootstrap_error "payload provenance is required but unavailable for ${ASSET}."
      bootstrap_error "${BOOTSTRAP_PROVENANCE_REASON:-verifier unavailable}"
      exit 1
    fi
    ;;
  *)
    bootstrap_error "payload provenance verification failed for ${ASSET}."
    bootstrap_error "${BOOTSTRAP_PROVENANCE_REASON:-unknown provenance failure}"
    exit 1
    ;;
esac

bootstrap_validate_archive_listing "${ARCHIVE}" "${NAMES_FILE}" "${TYPES_FILE}"
if ! tar -xzf "${ARCHIVE}" -C "${STAGE_DIR}"; then
  bootstrap_error "payload extraction failed."
  exit 1
fi
bootstrap_validate_extracted_payload "${STAGE_DIR}" "${VERSION}"

if [[ "${CLEAN_HELP_REQUESTED}" == "1" ]]; then
  help_rc=0
  bootstrap_run_setup_script "${STAGE_DIR}/setup.sh" || help_rc=$?
  [[ "${help_rc}" -eq 0 ]] || exit "${help_rc}"
  bootstrap_finish_cleanup || exit 1
  exit 0
fi

# Recheck conflicts after all remote input has been verified and while the
# bootstrap lock remains held. Existing version directories are immutable.
EXISTING_FINAL=0
EXISTING_TRANSACTION=0
if [[ -e "${TRANSACTION_FILE}" || -L "${TRANSACTION_FILE}" ]]; then
  if [[ ! -f "${TRANSACTION_FILE}" || -L "${TRANSACTION_FILE}" ]] \
    || ! bootstrap_transaction_read "${TRANSACTION_FILE}" \
    || [[ "${BOOTSTRAP_TRANSACTION_VERSION}" != "${VERSION}" ]] \
    || [[ "${BOOTSTRAP_TRANSACTION_SHA256}" != "${BOOTSTRAP_PAYLOAD_SHA256}" ]]; then
    bootstrap_error "existing distribution transaction does not match the verified payload: ${FINAL_DIR}"
    exit 73
  fi
  EXISTING_TRANSACTION=1
fi
if [[ -e "${FINAL_DIR}" || -L "${FINAL_DIR}" ]]; then
  if [[ "${EXISTING_TRANSACTION}" != "1" ]]; then
    bootstrap_error "existing distribution has no verified transaction: ${FINAL_DIR}"
    exit 73
  fi
  if [[ ! -d "${FINAL_DIR}" || -L "${FINAL_DIR}" ]] \
    || ! bootstrap_validate_extracted_payload "${FINAL_DIR}" "${VERSION}"; then
    bootstrap_error "existing distribution failed payload validation: ${FINAL_DIR}"
    exit 73
  fi
  payload_difference=""
  if ! payload_difference="$(diff -qr "${STAGE_DIR}" "${FINAL_DIR}" 2>&1)"; then
    bootstrap_error "existing distribution contents differ from the verified payload: ${FINAL_DIR}"
    bootstrap_error "${payload_difference%%$'\n'*}"
    exit 73
  fi
  bootstrap_payload_entry_modes_match \
    "${STAGE_DIR}" "${FINAL_DIR}" "${BOOTSTRAP_TMP}" || exit 73
  EXISTING_FINAL=1
elif [[ "${EXISTING_TRANSACTION}" == "1" ]]; then
  case "${BOOTSTRAP_TRANSACTION_PHASE}" in
    prepared)
      if [[ "${CLEAN_REQUESTED}" != "1" ]]; then
        mv "${STAGE_DIR}" "${FINAL_DIR}"
        EXISTING_FINAL=1
      fi
      ;;
    cleaning)
      [[ "${CLEAN_REQUESTED}" == "1" ]] || {
        bootstrap_error "bootstrap clean transaction is incomplete; rerun --clean."
        exit 73
      }
      ;;
    setup|committed)
      bootstrap_error "${BOOTSTRAP_TRANSACTION_PHASE} transaction exists without its distribution: ${TRANSACTION_FILE}"
      exit 73
      ;;
  esac
fi

if [[ "${CLEAN_REQUESTED}" == "1" ]]; then
  bootstrap_prepare_clean_plan "${DIST_ROOT}" "${CURRENT_LINK}" || exit 73
  SETUP_STARTED=1
  if [[ "${EXISTING_TRANSACTION}" == "1" ]]; then
    bootstrap_transaction_write "${TRANSACTION_FILE}" "${DIST_ROOT}" \
      "${VERSION}" "${BOOTSTRAP_PAYLOAD_SHA256}" "cleaning"
  fi
  printf 'Payload verified: checksum=%s provenance=%s\n' \
    "${BOOTSTRAP_PAYLOAD_SHA256}" "${BOOTSTRAP_PROVENANCE_STATUS}"
  clean_rc=0
  bootstrap_run_setup_script "${STAGE_DIR}/setup.sh" || clean_rc=$?
  [[ "${clean_rc}" -eq 0 ]] || exit "${clean_rc}"
  bootstrap_apply_clean_plan "${DIST_ROOT}" "${CURRENT_LINK}" || exit 73
  bootstrap_finish_cleanup || exit 1
  exit 0
fi

if [[ "${EXISTING_FINAL}" == "1" ]]; then
  printf 'Resuming verified bootstrap transaction phase=%s.\n' \
    "${BOOTSTRAP_TRANSACTION_PHASE}"
else
  bootstrap_transaction_write "${TRANSACTION_FILE}" "${DIST_ROOT}" \
    "${VERSION}" "${BOOTSTRAP_PAYLOAD_SHA256}" "prepared"
  TRANSACTION_OWNED=1
  mv "${STAGE_DIR}" "${FINAL_DIR}"
  FINAL_DIR_OWNED=1
fi
if [[ -e "${CURRENT_LINK}" && ! -L "${CURRENT_LINK}" ]]; then
  bootstrap_error "dist/current became a non-symlink; refusing to overwrite it."
  exit 73
fi
if [[ -L "${CURRENT_LINK}" ]]; then
  if ! PREVIOUS_CURRENT_TARGET="$(readlink "${CURRENT_LINK}")"; then
    bootstrap_error "could not read the previous dist/current symlink target."
    exit 1
  fi
  PREVIOUS_CURRENT_PRESENT=1
fi

if [[ ! -L "${CURRENT_LINK}" || "$(readlink "${CURRENT_LINK}")" != "${VERSION}" ]]; then
  CURRENT_TMP="${BOOTSTRAP_TMP}/current-link"
  if [[ -e "${CURRENT_TMP}" || -L "${CURRENT_TMP}" ]]; then
    bootstrap_error "temporary current-link path already exists: ${CURRENT_TMP}"
    exit 73
  fi
  ln -s "${VERSION}" "${CURRENT_TMP}"
  bootstrap_atomic_replace_symlink "${CURRENT_TMP}" "${CURRENT_LINK}"
  if [[ ! -L "${CURRENT_LINK}" || "$(readlink "${CURRENT_LINK}")" != "${VERSION}" ]]; then
    bootstrap_error "atomic dist/current switch could not be verified."
    exit 1
  fi
  CURRENT_SWITCHED=1
fi

printf 'Payload verified: checksum=%s provenance=%s\n' \
  "${BOOTSTRAP_PAYLOAD_SHA256}" "${BOOTSTRAP_PROVENANCE_STATUS}"

if [[ "${REQUIRE_PROVENANCE}" == "1" ]]; then
  case "${SETUP_ARGS[0]:-}" in
    install)
      setup_has_pack=0
      for setup_arg in "${SETUP_ARGS[@]:1}"; do
        if [[ "${setup_arg}" == "--pack" || "${setup_arg}" == --pack=* ]]; then
          setup_has_pack=1
          break
        fi
      done
      if [[ "${setup_has_pack}" == "0" ]]; then
        SETUP_ARGS=(install --require-provenance "${SETUP_ARGS[@]:1}")
        SETUP_ARG_COUNT=$((SETUP_ARG_COUNT + 1))
      fi
      ;;
    doctor|verify-install|verify-project|verify-dev-repo|--check|--clean|--codex-status|packs|demo|--help|-h|help)
      # Bootstrap already enforced payload provenance. These dispatcher
      # commands do not enter the install option parser.
      ;;
    *)
      bootstrap_prepend_setup_arg --require-provenance
      ;;
  esac
fi
setup_rc=0
bootstrap_transaction_write "${TRANSACTION_FILE}" "${DIST_ROOT}" \
  "${VERSION}" "${BOOTSTRAP_PAYLOAD_SHA256}" "setup"
SETUP_STARTED=1
bootstrap_run_setup_script "${FINAL_DIR}/setup.sh" || setup_rc=$?
if [[ "${setup_rc}" -ne 0 ]]; then
  bootstrap_error "payload setup failed with exit status ${setup_rc}; preserving verified payload for repair."
  exit "${setup_rc}"
fi

bootstrap_transaction_write "${TRANSACTION_FILE}" "${DIST_ROOT}" \
  "${VERSION}" "${BOOTSTRAP_PAYLOAD_SHA256}" "committed"
TRANSACTION_COMMITTED=1
CURRENT_SWITCHED=0
FINAL_DIR_OWNED=0
TRANSACTION_OWNED=0
rm -rf -- "${BOOTSTRAP_TMP}"
BOOTSTRAP_TMP=""
bootstrap_release_owner_lock

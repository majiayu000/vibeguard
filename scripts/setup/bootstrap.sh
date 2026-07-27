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
BOOTSTRAP_TMP=""
LOCK_HELD=0
FINAL_DIR_OWNED=0
PREVIOUS_CURRENT_PRESENT=0
PREVIOUS_CURRENT_TARGET=""
CURRENT_SWITCHED=0
TRANSACTION_COMMITTED=0
LOCK_OWNER_PID=""
LOCK_OWNER_NONCE=""

bootstrap_acquire_owner_lock() {
  local attempt

  for attempt in 1 2 3; do
    if mkdir "${LOCK_DIR}" 2>/dev/null; then
      LOCK_OWNER_PID="$$"
      LOCK_OWNER_NONCE="$$-${RANDOM}-${attempt}"
      if ! printf 'pid=%s\nnonce=%s\n' "${LOCK_OWNER_PID}" "${LOCK_OWNER_NONCE}" \
        > "${LOCK_DIR}/owner"; then
        bootstrap_error "could not initialize bootstrap lock owner metadata."
        if ! rm -f -- "${LOCK_DIR}/owner" || ! rmdir "${LOCK_DIR}"; then
          bootstrap_error "failed to clean partially initialized bootstrap lock."
        fi
        return 1
      fi
      LOCK_HELD=1
      return 0
    fi
    if [[ -L "${LOCK_DIR}" || ! -d "${LOCK_DIR}" ]]; then
      bootstrap_error "bootstrap lock must be a real directory: ${LOCK_DIR}"
      return 73
    fi
    if ! bootstrap_lock_read_owner "${LOCK_DIR}"; then
      return 73
    fi
    if kill -0 "${BOOTSTRAP_LOCK_READ_PID}" 2>/dev/null; then
      bootstrap_error "active bootstrap owner pid=${BOOTSTRAP_LOCK_READ_PID} holds ${LOCK_DIR}."
      return 73
    fi
    if ! bootstrap_lock_reap_exact_owner \
      "${LOCK_DIR}" "${DIST_ROOT}" \
      "${BOOTSTRAP_LOCK_READ_PID}" "${BOOTSTRAP_LOCK_READ_NONCE}" \
      "stale-lock recovery"; then
      return 73
    fi
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
  if [[ "${TRANSACTION_COMMITTED}" == "0" && "${CURRENT_SWITCHED}" == "1" ]]; then
    if ! bootstrap_restore_previous_current; then
      status=1
    fi
  fi
  if [[ "${FINAL_DIR_OWNED}" == "1" && "${TRANSACTION_COMMITTED}" == "0" \
    && "${CURRENT_SWITCHED}" == "0" ]]; then
    if ! rm -rf -- "${FINAL_DIR}"; then
      bootstrap_error "failed to remove newly owned distribution after bootstrap failure: ${FINAL_DIR}"
      status=1
    fi
  elif [[ "${FINAL_DIR_OWNED}" == "1" && "${TRANSACTION_COMMITTED}" == "0" ]]; then
    bootstrap_error "rollback incomplete; retaining current-referenced distribution evidence: ${FINAL_DIR}"
    status=1
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

if [[ -e "${FINAL_DIR}" || -L "${FINAL_DIR}" ]]; then
  bootstrap_error "distribution version already exists; refusing to overwrite: ${FINAL_DIR}"
  exit 73
fi
if [[ -e "${CURRENT_LINK}" && ! -L "${CURRENT_LINK}" ]]; then
  bootstrap_error "dist/current exists and is not a symlink; refusing to overwrite it."
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

# Recheck conflicts after all remote input has been verified and while the
# bootstrap lock remains held. Existing version directories are immutable.
if [[ -e "${FINAL_DIR}" || -L "${FINAL_DIR}" ]]; then
  bootstrap_error "distribution version appeared during bootstrap; refusing to overwrite: ${FINAL_DIR}"
  exit 73
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

mv "${STAGE_DIR}" "${FINAL_DIR}"
FINAL_DIR_OWNED=1
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

printf 'Payload verified: checksum=%s provenance=%s\n' \
  "${BOOTSTRAP_PAYLOAD_SHA256}" "${BOOTSTRAP_PROVENANCE_STATUS}"

if [[ "${REQUIRE_PROVENANCE}" == "1" ]]; then
  case "${SETUP_ARGS[0]:-}" in
    install)
      SETUP_ARGS=(install --require-provenance "${SETUP_ARGS[@]:1}")
      ;;
    doctor|verify-install|verify-project|verify-dev-repo|--check|--clean|--codex-status|packs|demo|--help|-h|help)
      # Bootstrap already enforced payload provenance. These dispatcher
      # commands do not enter the install option parser.
      ;;
    *)
      SETUP_ARGS=(--require-provenance "${SETUP_ARGS[@]}")
      ;;
  esac
fi
setup_rc=0
bash "${FINAL_DIR}/setup.sh" "${SETUP_ARGS[@]}" || setup_rc=$?
if [[ "${setup_rc}" -ne 0 ]]; then
  bootstrap_error "payload setup failed with exit status ${setup_rc}; rolling back bootstrap transaction."
  exit "${setup_rc}"
fi

TRANSACTION_COMMITTED=1
CURRENT_SWITCHED=0
FINAL_DIR_OWNED=0
rm -rf -- "${BOOTSTRAP_TMP}"
BOOTSTRAP_TMP=""
bootstrap_release_owner_lock

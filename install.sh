#!/usr/bin/env bash
# Hosted VibeGuard bootstrap seed (GH699).
#
# This entrypoint never installs from its own checkout. It downloads one exact
# release payload, verifies it, extracts only the canonical bootstrap seed, and
# delegates installation to scripts/setup/bootstrap.sh from that verified
# payload.

set -euo pipefail
umask 077

readonly RELEASE_REPO="majiayu000/vibeguard"
VERSION=""
REQUIRE_PROVENANCE=0
INSTALL_TMP=""
declare -a SETUP_ARGS=()
SETUP_ARG_COUNT=0
DRY_RUN_REQUESTED=0

error() { printf 'ERROR: %s\n' "$1" >&2; }

cleanup() {
  if [[ -n "${INSTALL_TMP:-}" && -d "${INSTALL_TMP}" ]]; then
    rm -rf -- "${INSTALL_TMP}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

usage() {
  cat <<'USAGE'
Usage: install.sh --version X.Y.Z [--require-provenance] [-- SETUP_ARGS...]

Downloads one exact VibeGuard release payload, verifies it, and delegates to
the canonical no-clone bootstrap contained in that verified payload.

Examples:
  install.sh --version 1.2.3
  install.sh --version 1.2.3 --require-provenance -- --profile full
USAGE
}

validate_version() {
  local value="$1"
  local core_and_prerelease="${value}"
  local core prerelease="" build="" identifier
  local -a identifiers=()

  if [[ "${core_and_prerelease}" == *+* ]]; then
    build="${core_and_prerelease#*+}"
    core_and_prerelease="${core_and_prerelease%%+*}"
    [[ "${build}" != *+* ]] || return 1
    [[ "${build}" =~ ^[0-9A-Za-z-]+([.][0-9A-Za-z-]+)*$ ]] || return 1
  fi
  if [[ "${core_and_prerelease}" == *-* ]]; then
    core="${core_and_prerelease%%-*}"
    prerelease="${core_and_prerelease#*-}"
    [[ "${prerelease}" =~ ^[0-9A-Za-z-]+([.][0-9A-Za-z-]+)*$ ]] || return 1
    IFS='.' read -r -a identifiers <<< "${prerelease}"
    for identifier in "${identifiers[@]}"; do
      if [[ "${identifier}" =~ ^[0-9]+$ \
        && "${identifier}" == 0* && "${identifier}" != "0" ]]; then
        return 1
      fi
    done
  else
    core="${core_and_prerelease}"
  fi
  [[ "${core}" =~ ^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)$ ]]
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${path}" | awk '{print $1}'
  else
    error "sha256sum or shasum is required to verify the release payload."
    return 1
  fi
}

verify_checksum() {
  local asset_path="$1" sums_path="$2" asset_name="$3"
  local expected actual

  expected="$(
    awk -v file="${asset_name}" '
      ($2 == file || $2 == "*" file) { count += 1; digest = $1 }
      END { if (count == 1) print digest; else exit 1 }
    ' "${sums_path}"
  )" || {
    error "SHA256SUMS must contain exactly one entry for ${asset_name}."
    return 1
  }
  if [[ ${#expected} -ne 64 || "${expected}" == *[!0-9a-f]* ]]; then
    error "SHA256SUMS contains an invalid digest for ${asset_name}."
    return 1
  fi
  actual="$(sha256_file "${asset_path}")"
  if [[ "${actual}" != "${expected}" ]]; then
    error "payload checksum verification failed for ${asset_name}."
    return 1
  fi
}

verify_provenance() {
  local asset_path="$1" tag="$2"
  command -v gh >/dev/null 2>&1 || {
    error "payload provenance is required but gh is unavailable."
    return 1
  }
  gh attestation verify --help >/dev/null 2>&1 || {
    error "payload provenance is required but gh attestation verify is unavailable."
    return 1
  }
  gh auth status >/dev/null 2>&1 || {
    error "payload provenance is required but gh authentication is unavailable."
    return 1
  }
  gh attestation verify "${asset_path}" \
    --repo "${RELEASE_REPO}" \
    --signer-workflow "github.com/${RELEASE_REPO}/.github/workflows/release.yml" \
    --source-ref "refs/tags/${tag}" \
    --deny-self-hosted-runners >/dev/null 2>&1 || {
      error "payload provenance verification failed."
      return 1
    }
}

extract_bootstrap_seed() {
  local archive="$1" seed_root="$2" path entry_type destination
  local -a seed_paths=(
    scripts/setup/bootstrap.sh
    scripts/setup/bootstrap-lib.sh
    scripts/setup/bootstrap_birth_token.jxa
    scripts/setup/bootstrap_identity.sh
    scripts/setup/bootstrap_lease_terminal.sh
    scripts/setup/bootstrap_lease_retirement.sh
    scripts/setup/bootstrap_process.sh
    scripts/setup/bootstrap_termination.sh
    scripts/setup/bootstrap_state.sh
  )

  mkdir -p "${seed_root}/scripts/setup"
  for path in "${seed_paths[@]}"; do
    entry_type="$(LC_ALL=C tar -tvzf "${archive}" "${path}" | awk 'NR == 1 { print substr($0, 1, 1) }')"
    if [[ "${entry_type}" != "-" ]]; then
      error "verified payload seed entry is missing or not a regular file: ${path}"
      return 1
    fi
    destination="${seed_root}/${path}"
    if ! tar -xOzf "${archive}" "${path}" > "${destination}"; then
      error "could not extract verified bootstrap seed entry: ${path}"
      return 1
    fi
  done
  chmod 0755 "${seed_root}/scripts/setup/bootstrap.sh"
}

setup_args_include_dry_run() {
  local index=0
  while [[ "${index}" -lt "${SETUP_ARG_COUNT}" ]]; do
    if [[ "${SETUP_ARGS[${index}]}" == "--dry-run" ]]; then
      return 0
    fi
    index=$((index + 1))
  done
  return 1
}

run_verified_dry_run() {
  local archive="$1" seed_root="$2" payload_root="$3"
  local names_file="${INSTALL_TMP}/archive-names"
  local types_file="${INSTALL_TMP}/archive-types"
  local setup_arg setup_has_pack

  # Reuse the canonical bootstrap validators; do not add a second archive
  # validation contract to the hosted seed.
  # shellcheck source=scripts/setup/bootstrap-lib.sh
  source "${seed_root}/scripts/setup/bootstrap-lib.sh"
  mkdir -p "${payload_root}"
  bootstrap_validate_archive_listing "${archive}" "${names_file}" "${types_file}"
  if ! tar -xzf "${archive}" -C "${payload_root}"; then
    error "payload extraction failed."
    return 1
  fi
  bootstrap_validate_extracted_payload "${payload_root}" "${VERSION}"

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
        fi
        ;;
      doctor|verify-install|verify-project|verify-dev-repo|--check|--clean|--codex-status|packs|demo|--help|-h|help)
        ;;
      *)
        SETUP_ARGS=(--require-provenance "${SETUP_ARGS[@]}")
        ;;
    esac
  fi

  printf 'Payload verified for dry run; dist/current is unchanged.\n'
  bash "${payload_root}/setup.sh" "${SETUP_ARGS[@]}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || { error "--version requires an exact X.Y.Z value."; exit 64; }
      [[ -z "${VERSION}" ]] || { error "--version may be provided only once."; exit 64; }
      VERSION="${2#v}"
      shift 2
      ;;
    --version=*)
      [[ -z "${VERSION}" ]] || { error "--version may be provided only once."; exit 64; }
      VERSION="${1#*=}"
      VERSION="${VERSION#v}"
      shift
      ;;
    --require-provenance)
      [[ "${REQUIRE_PROVENANCE}" == "0" ]] || {
        error "--require-provenance may be provided only once."
        exit 64
      }
      REQUIRE_PROVENANCE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      SETUP_ARGS=("$@")
      SETUP_ARG_COUNT=$#
      break
      ;;
    *)
      error "unknown installer argument: $1"
      usage >&2
      exit 64
      ;;
  esac
done

if ! validate_version "${VERSION}"; then
  error "--version must be an exact semantic version; floating latest is forbidden."
  exit 64
fi
command -v curl >/dev/null 2>&1 || { error "curl is required."; exit 1; }
command -v tar >/dev/null 2>&1 || { error "tar is required."; exit 1; }

TAG="v${VERSION}"
ASSET="vibeguard-payload-${VERSION}.tar.gz"
BASE_URL="https://github.com/${RELEASE_REPO}/releases/download/${TAG}"
INSTALL_TMP="$(mktemp -d "${TMPDIR:-/tmp}/vibeguard-install.XXXXXX")"
ARCHIVE="${INSTALL_TMP}/${ASSET}"
SUMS="${INSTALL_TMP}/SHA256SUMS"
SEED_ROOT="${INSTALL_TMP}/seed"

printf 'Downloading exact VibeGuard release %s...\n' "${TAG}"
curl -fsSL -o "${ARCHIVE}" "${BASE_URL}/${ASSET}"
curl -fsSL -o "${SUMS}" "${BASE_URL}/SHA256SUMS"
verify_checksum "${ARCHIVE}" "${SUMS}" "${ASSET}"
if [[ "${REQUIRE_PROVENANCE}" == "1" ]]; then
  verify_provenance "${ARCHIVE}" "${TAG}"
fi
extract_bootstrap_seed "${ARCHIVE}" "${SEED_ROOT}"
if setup_args_include_dry_run; then
  DRY_RUN_REQUESTED=1
fi

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
      SETUP_ARGS=(install --yes "${SETUP_ARGS[@]:1}")
    fi
    ;;
  doctor|verify-install|verify-project|verify-dev-repo|--check|--clean|--codex-status|packs|demo|--help|-h|help)
    ;;
  *)
    if [[ "${SETUP_ARG_COUNT}" == "0" ]]; then
      SETUP_ARGS=(--yes)
    else
      SETUP_ARGS=(--yes "${SETUP_ARGS[@]}")
    fi
    ;;
esac

if [[ "${DRY_RUN_REQUESTED}" == "1" ]]; then
  run_verified_dry_run "${ARCHIVE}" "${SEED_ROOT}" "${INSTALL_TMP}/payload"
  exit 0
fi

bootstrap_args=(--version "${VERSION}")
if [[ "${REQUIRE_PROVENANCE}" == "1" ]]; then
  bootstrap_args+=(--require-provenance)
fi
bootstrap_args+=(-- "${SETUP_ARGS[@]}")
bash "${SEED_ROOT}/scripts/setup/bootstrap.sh" "${bootstrap_args[@]}"

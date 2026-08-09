#!/usr/bin/env bash
# One-command VibeGuard installer (GH699).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/majiayu000/vibeguard/main/install.sh | bash
#   curl ... | bash -s -- --profile full --with-scheduler
#
# This script downloads the pinned release payload and runtime, verifies
# checksums, and runs the same setup.sh path as a git-clone install.

set -euo pipefail

REPO_OWNER="${VIBEGUARD_INSTALL_REPO_OWNER:-majiayu000}"
REPO_NAME="${VIBEGUARD_INSTALL_REPO_NAME:-vibeguard}"
RELEASE_REPO="${REPO_OWNER}/${REPO_NAME}"

VERSION="${VIBEGUARD_INSTALL_VERSION:-}"
INSTALL_TMP=""

err() { printf 'ERROR: %s\n' "$1" >&2; }

cleanup() {
  if [[ -n "${INSTALL_TMP:-}" && -d "${INSTALL_TMP}" ]]; then
    rm -rf "${INSTALL_TMP}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

print_usage() {
  cat <<'USAGE'
Usage: curl -fsSL .../install.sh | bash [ -- [setup-options] ]

The trailing arguments are forwarded to setup.sh. Common options:
  --yes                  Apply installation without prompting
  --profile minimal|core|full|strict
  --languages lang1,...
  --with-scheduler       Opt in to scheduled GC
  --dry-run              Show diffs without writing

Environment overrides (mostly for tests):
  VIBEGUARD_INSTALL_VERSION       e.g. 1.2.3
  VIBEGUARD_INSTALL_REPO_OWNER
  VIBEGUARD_INSTALL_REPO_NAME
USAGE
}

resolve_version() {
  local version=""

  if [[ -n "${VERSION}" ]]; then
    version="${VERSION}"
  elif command -v curl >/dev/null 2>&1; then
    version="$(
      curl -fsSL "https://api.github.com/repos/${RELEASE_REPO}/releases/latest" 2>/dev/null \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' \
        | head -n 1
    )" || true
  fi

  if [[ -z "${version}" ]] && command -v curl >/dev/null 2>&1; then
    version="$(
      curl -fsSL "https://raw.githubusercontent.com/${RELEASE_REPO}/main/vibeguard-runtime/VERSION" 2>/dev/null \
        | tr -d '[:space:]'
    )" || true
  fi

  if [[ -z "${version}" ]]; then
    err "could not resolve a release version (set VIBEGUARD_INSTALL_VERSION or ensure curl is available)"
    return 1
  fi

  version="${version#v}"
  printf '%s\n' "${version}"
}

detect_target() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "${os}:${arch}" in
    Darwin:arm64|Darwin:aarch64)
      printf 'aarch64-apple-darwin' ;;
    Darwin:x86_64|Darwin:amd64)
      printf 'x86_64-apple-darwin' ;;
    Linux:x86_64|Linux:amd64)
      printf 'x86_64-unknown-linux-musl' ;;
    Linux:aarch64|Linux:arm64)
      printf 'aarch64-unknown-linux-musl' ;;
    *)
      err "unsupported platform: ${os}/${arch}"
      return 1 ;;
  esac
}

download_file() {
  local url="$1" dest="$2"
  if ! command -v curl >/dev/null 2>&1; then
    err "curl is required to download release assets"
    return 1
  fi
  curl -fsSL -o "${dest}" "${url}"
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${path}" | awk '{print $1}'
  else
    err "sha256sum or shasum is required to verify release assets"
    return 1
  fi
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        print_usage
        exit 0 ;;
      *)
        break ;;
    esac
  done

  local version target payload_asset base_url tmp_dir sums_file payload_file payload_dir
  local expected actual

  version="$(resolve_version)"
  target="$(detect_target)"

  payload_asset="vibeguard-payload-${version}.tar.gz"
  base_url="https://github.com/${RELEASE_REPO}/releases/download/v${version}"

  INSTALL_TMP="$(mktemp -d "${TMPDIR:-/tmp}/vibeguard-install_XXXXXX")"
  tmp_dir="${INSTALL_TMP}"
  sums_file="${tmp_dir}/SHA256SUMS"
  payload_file="${tmp_dir}/${payload_asset}"
  payload_dir="${tmp_dir}/payload"

  printf 'Installing VibeGuard %s for %s...\n' "${version}" "${target}"

  printf 'Downloading %s...\n' "${payload_asset}"
  download_file "${base_url}/${payload_asset}" "${payload_file}"
  printf 'Downloading SHA256SUMS...\n'
  download_file "${base_url}/SHA256SUMS" "${sums_file}"

  expected="$(awk -v file="${payload_asset}" '($2 == file || $2 == "*" file) { print $1; exit }' "${sums_file}")"
  if [[ -z "${expected}" ]]; then
    err "SHA256SUMS missing entry for ${payload_asset}"
    return 1
  fi

  if ! actual="$(sha256_file "${payload_file}")"; then
    return 1
  fi
  if [[ "${actual}" != "${expected}" ]]; then
    err "checksum verification failed for ${payload_asset}"
    err "  expected: ${expected}"
    err "  actual:   ${actual}"
    return 1
  fi
  printf 'Checksum verified.\n'

  mkdir -p "${payload_dir}"
  tar -xzf "${payload_file}" -C "${payload_dir}"

  if [[ ! -f "${payload_dir}/setup.sh" ]]; then
    err "extracted payload is missing setup.sh"
    return 1
  fi

  printf 'Running setup...\n'
  bash "${payload_dir}/setup.sh" --yes "$@"

  printf 'Verifying install...\n'
  bash "${payload_dir}/setup.sh" verify-install

  printf 'VibeGuard %s installed and verified.\n' "${version}"
}

main "$@"

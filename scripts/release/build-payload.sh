#!/usr/bin/env bash
# Build the vibeguard-payload release artifact (GH699).
#
# Packages the tracked paths listed in scripts/release/payload-manifest.txt
# into vibeguard-payload-<version>.tar.gz, with a .vibeguard-payload marker at
# the archive root so setup.sh can detect payload mode.
#
# Usage:
#   bash scripts/release/build-payload.sh [--version X.Y.Z] [--output DIR] [--ref REF]
#
# Defaults: version from vibeguard-runtime/VERSION, output dist/, ref HEAD.
# Content always comes from the git tree (git archive), never from the dirty
# working directory.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
MANIFEST="${REPO_DIR}/scripts/release/payload-manifest.txt"
MARKER_NAME=".vibeguard-payload"

VERSION=""
OUTPUT_DIR="${REPO_DIR}/dist"
GIT_REF="HEAD"

err() { printf 'ERROR: %s\n' "$1" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -lt 2 ]] && { err "--version requires a value"; exit 64; }
      VERSION="$2"; shift 2 ;;
    --version=*)
      VERSION="${1#*=}"; shift ;;
    --output)
      [[ $# -lt 2 ]] && { err "--output requires a value"; exit 64; }
      OUTPUT_DIR="$2"; shift 2 ;;
    --output=*)
      OUTPUT_DIR="${1#*=}"; shift ;;
    --ref)
      [[ $# -lt 2 ]] && { err "--ref requires a value"; exit 64; }
      GIT_REF="$2"; shift 2 ;;
    --ref=*)
      GIT_REF="${1#*=}"; shift ;;
    *)
      err "unknown argument: $1"
      err "usage: bash scripts/release/build-payload.sh [--version X.Y.Z] [--output DIR] [--ref REF]"
      exit 64 ;;
  esac
done

if [[ ! -f "${MANIFEST}" ]]; then
  err "payload manifest not found: ${MANIFEST}"
  exit 1
fi

if [[ -z "${VERSION}" ]]; then
  VERSION="$(git -C "${REPO_DIR}" show "${GIT_REF}:vibeguard-runtime/VERSION" 2>/dev/null | tr -d '[:space:]')"
fi
if [[ -z "${VERSION}" ]]; then
  err "payload version could not be resolved (pass --version or ensure vibeguard-runtime/VERSION exists at ${GIT_REF})"
  exit 1
fi
case "${VERSION}" in
  v*) VERSION="${VERSION#v}" ;;
esac

# Collect manifest entries.
manifest_entries=()
while IFS= read -r line; do
  line="${line%%#*}"
  line="$(printf '%s' "${line}" | tr -d '[:space:]')"
  [[ -z "${line}" ]] && continue
  manifest_entries+=("${line}")
done < "${MANIFEST}"

if [[ ${#manifest_entries[@]} -eq 0 ]]; then
  err "payload manifest is empty: ${MANIFEST}"
  exit 1
fi

# Every manifest entry must resolve to at least one tracked file at GIT_REF.
missing=0
for entry in "${manifest_entries[@]}"; do
  if ! git -C "${REPO_DIR}" ls-tree --name-only "${GIT_REF}" -- "${entry}" | grep -q .; then
    err "manifest entry has no tracked content at ${GIT_REF}: ${entry}"
    missing=1
  fi
done
if [[ "${missing}" -ne 0 ]]; then
  exit 1
fi

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/vibeguard-payload_XXXXXX")"
cleanup() { rm -rf "${STAGING}" 2>/dev/null || true; }
trap cleanup EXIT

# Export the manifest subset of the tracked tree; never the working directory.
git -C "${REPO_DIR}" archive "${GIT_REF}" -- "${manifest_entries[@]}" | tar -x -C "${STAGING}"

manifest_sha256="$(shasum -a 256 "${MANIFEST}" | awk '{print $1}')"
git_commit="$(git -C "${REPO_DIR}" rev-parse --short "${GIT_REF}")"
{
  printf 'version=%s\n' "${VERSION}"
  printf 'manifest_sha256=%s\n' "${manifest_sha256}"
  printf 'git_commit=%s\n' "${git_commit}"
} > "${STAGING}/${MARKER_NAME}"

# The payload must carry a runtime VERSION that matches its own version, so a
# payload install always downloads the release binary it was published with.
payload_runtime_version="$(tr -d '[:space:]' < "${STAGING}/vibeguard-runtime/VERSION")"
if [[ "${payload_runtime_version}" != "${VERSION}" ]]; then
  err "payload version ${VERSION} does not match vibeguard-runtime/VERSION (${payload_runtime_version}) at ${GIT_REF}"
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"
ARCHIVE="${OUTPUT_DIR}/vibeguard-payload-${VERSION}.tar.gz"
tar -czf "${ARCHIVE}" -C "${STAGING}" .

file_count="$(tar -tzf "${ARCHIVE}" | grep -cv '/$')"
printf 'payload: %s (%s files, version %s, commit %s)\n' \
  "${ARCHIVE}" "${file_count}" "${VERSION}" "${git_commit}"

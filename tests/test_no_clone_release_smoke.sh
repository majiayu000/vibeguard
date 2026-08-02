#!/usr/bin/env bash
# Contract tests for the release-backed, no-checkout GH699 smoke job.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="${REPO_DIR}/.github/workflows/release.yml"

PASS=0
FAIL=0

check_contains() {
  local description="$1" pattern="$2"
  if grep -Fq -- "${pattern}" "${JOB_FILE}"; then
    printf 'PASS: %s\n' "${description}"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s\n' "${description}" >&2
    FAIL=$((FAIL + 1))
  fi
}

check_absent() {
  local description="$1" pattern="$2"
  if grep -Fq -- "${pattern}" "${JOB_FILE}"; then
    printf 'FAIL: %s\n' "${description}" >&2
    FAIL=$((FAIL + 1))
  else
    printf 'PASS: %s\n' "${description}"
    PASS=$((PASS + 1))
  fi
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibeguard-no-clone-smoke.XXXXXX")"
trap 'rm -rf "${TMP_ROOT}"' EXIT
JOB_FILE="${TMP_ROOT}/job.yml"

awk '
  /^  no-clone-smoke:/ { capture = 1 }
  capture { print }
' "${WORKFLOW}" > "${JOB_FILE}"

if [[ ! -s "${JOB_FILE}" ]]; then
  printf 'FAIL: release workflow has no no-clone-smoke job\n' >&2
  exit 1
fi

check_contains "smoke waits for immutable release publication" "needs: publish-release"
check_contains "smoke runs on macOS" "os: macos-14"
check_contains "smoke runs on Linux" "os: ubuntu-latest"
check_contains "smoke receives only read access to release contents" "contents: read"
check_contains "smoke downloads the exact pinned payload" 'vibeguard-payload-${VERSION}.tar.gz'
check_contains "smoke downloads release assets with gh" 'gh release download "${TAG_NAME}"'
check_contains "checksum manifest requires one exact asset row" "count == 1"
check_contains "payload digest is computed before execution" 'actual="$(sha256_file "${DOWNLOAD_DIR}/${ASSET}")"'
check_contains "checksum mismatch fails visibly" "payload checksum verification failed"
check_contains "payload attestation is mandatory" 'gh attestation verify "${DOWNLOAD_DIR}/${ASSET}"'
check_contains "attestation signer is pinned to release workflow" "--signer-workflow"
check_contains "attestation source is pinned to exact tag" '--source-ref "refs/tags/${TAG_NAME}"'
check_contains "bootstrap seed accepts regular archive members only" 'substr($1, 1, 1) == "-"'
check_contains "bootstrap enforces payload provenance" '--version "${VERSION}" --require-provenance -- --yes --require-provenance'
check_contains "installed release runs canonical verification" 'setup.sh" verify-install'
check_absent "fresh-machine job never checks out the repository" "actions/checkout@"
check_absent "fresh-machine job never pipes curl into a shell" "curl | bash"
check_absent "fresh-machine job never pipes curl into sh" "curl | sh"
check_absent "fresh-machine job never prints the GitHub token" 'echo ${GH_TOKEN}'

printf '%s passed, %s failed\n' "${PASS}" "${FAIL}"
test "${FAIL}" -eq 0

#!/usr/bin/env bash
# VibeGuard payload artifact + payload-mode regression tests (GH699)
#
# Usage: bash tests/test_payload.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_PAYLOAD="${REPO_DIR}/scripts/release/build-payload.sh"
MANIFEST="${REPO_DIR}/scripts/release/payload-manifest.txt"

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header(){ printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

check() {
  local desc="$1" ok="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "${ok}" == "0" ]]; then
    green "${desc}"
    PASS=$((PASS + 1))
  else
    red "${desc}"
    FAIL=$((FAIL + 1))
  fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibeguard-payload-test_XXXXXX")"
cleanup() { rm -rf "${WORK}" 2>/dev/null || true; }
trap cleanup EXIT

header "payload manifest"

rc=0
grep -vE '^[[:space:]]*(#|$)' "${MANIFEST}" | while IFS= read -r entry; do
  if ! git -C "${REPO_DIR}" ls-files -- "${entry}" | grep -q .; then
    echo "missing tracked content: ${entry}" >&2
    exit 1
  fi
done || rc=1
check "every manifest entry resolves to tracked content" "${rc}"

rc=0
grep -qx 'setup.sh' "${MANIFEST}" || rc=1
grep -qx 'vibeguard-runtime/VERSION' "${MANIFEST}" || rc=1
grep -qx 'hooks' "${MANIFEST}" || rc=1
grep -qx 'rules' "${MANIFEST}" || rc=1
check "manifest keeps the install-critical entries" "${rc}"

rc=0
for dev_only in docs tests eval plan site; do
  if grep -qx "${dev_only}" "${MANIFEST}"; then
    rc=1
  fi
done
check "manifest excludes dev-only surfaces" "${rc}"

header "build-payload.sh"

VERSION="$(tr -d '[:space:]' < "${REPO_DIR}/vibeguard-runtime/VERSION")"
build_out="$(bash "${BUILD_PAYLOAD}" --output "${WORK}/dist" 2>&1)"
rc=$?
check "build-payload.sh builds from HEAD (exit 0)" "${rc}"

ARCHIVE="${WORK}/dist/vibeguard-payload-${VERSION}.tar.gz"
rc=0; [[ -f "${ARCHIVE}" ]] || rc=1
check "archive named vibeguard-payload-${VERSION}.tar.gz exists" "${rc}"

mkdir -p "${WORK}/unpacked"
tar -xzf "${ARCHIVE}" -C "${WORK}/unpacked"

rc=0; [[ -f "${WORK}/unpacked/.vibeguard-payload" ]] || rc=1
check "unpacked payload carries .vibeguard-payload marker" "${rc}"

rc=0
grep -q "^version=${VERSION}$" "${WORK}/unpacked/.vibeguard-payload" || rc=1
grep -q '^manifest_sha256=[0-9a-f]\{64\}$' "${WORK}/unpacked/.vibeguard-payload" || rc=1
grep -q '^git_commit=' "${WORK}/unpacked/.vibeguard-payload" || rc=1
check "marker records version, manifest sha256, and git commit" "${rc}"

rc=0
for required in setup.sh vibeguard-runtime/VERSION hooks/run-hook.sh rules scripts/setup/install.sh; do
  [[ -e "${WORK}/unpacked/${required}" ]] || { echo "missing: ${required}" >&2; rc=1; }
done
check "unpacked payload contains install-critical paths" "${rc}"

rc=0
for excluded in docs tests eval plan site .git vibeguard-runtime/src; do
  [[ ! -e "${WORK}/unpacked/${excluded}" ]] || { echo "unexpected: ${excluded}" >&2; rc=1; }
done
check "unpacked payload excludes dev-only paths" "${rc}"

rc=0
payload_runtime_version="$(tr -d '[:space:]' < "${WORK}/unpacked/vibeguard-runtime/VERSION")"
[[ "${payload_runtime_version}" == "${VERSION}" ]] || rc=1
check "payload runtime VERSION matches payload version" "${rc}"

rc=0
bash "${BUILD_PAYLOAD}" --version 0.0.0-mismatch --output "${WORK}/dist-mismatch" >/dev/null 2>&1 && rc=1 || true
check "version/runtime-VERSION mismatch fails the build" "${rc}"

header "payload mode behavior"

# Payload mode must reject --build-from-source before doing any work.
out="$(cd "${WORK}/unpacked" && bash setup.sh --dry-run --build-from-source 2>&1)" && rc=1 || rc=0
check "payload mode rejects --build-from-source" "${rc}"
rc=0
grep -q 'not available in payload mode' <<< "${out}" || rc=1
check "--build-from-source rejection names payload mode" "${rc}"

# verify-dev-repo is a checkout-only subcommand.
out="$(cd "${WORK}/unpacked" && bash setup.sh verify-dev-repo 2>&1)" && rc=1 || rc=0
check "payload mode rejects verify-dev-repo (non-zero)" "${rc}"
rc=0
grep -q 'not applicable in payload mode' <<< "${out}" || rc=1
check "verify-dev-repo rejection names payload mode" "${rc}"

# A git checkout must NOT enter payload mode even if a marker file appears.
out="$(cd "${REPO_DIR}" && VIBEGUARD_PAYLOAD_MODE=1 bash setup.sh verify-dev-repo --help 2>&1 || true)"
rc=0
grep -q 'not applicable in payload mode' <<< "${out}" && rc=1
check "checkout with .git never enters payload mode" "${rc}"

echo
echo "=============================="
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' "${TOTAL}" "${PASS}" "${FAIL}"
echo "=============================="
[[ "${FAIL}" -eq 0 ]]

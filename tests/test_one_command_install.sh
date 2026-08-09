#!/usr/bin/env bash
# Regression tests for the one-command curl-pipe installer (GH699).
#
# Usage: bash tests/test_one_command_install.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_PAYLOAD="${REPO_DIR}/scripts/release/build-payload.sh"

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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibeguard-one-command-test_XXXXXX")"
cleanup() { rm -rf "${WORK}" 2>/dev/null || true; }
trap cleanup EXIT

VERSION="$(tr -d '[:space:]' < "${REPO_DIR}/vibeguard-runtime/VERSION")"

header "build payload release asset"

mkdir -p "${WORK}/release-assets"
build_out="$(bash "${BUILD_PAYLOAD}" --output "${WORK}/release-assets" 2>&1)"
rc=$?
check "build-payload.sh succeeds" "${rc}"
PAYLOAD_ASSET="vibeguard-payload-${VERSION}.tar.gz"
rc=0; [[ -f "${WORK}/release-assets/${PAYLOAD_ASSET}" ]] || rc=1
check "payload archive exists" "${rc}"

header "prepare runtime fixture"

cargo build --quiet --manifest-path "${REPO_DIR}/vibeguard-runtime/Cargo.toml"
case "$(uname -s):$(uname -m)" in
  Darwin:arm64|Darwin:aarch64) RELEASE_TARGET="aarch64-apple-darwin" ;;
  Darwin:x86_64|Darwin:amd64) RELEASE_TARGET="x86_64-apple-darwin" ;;
  Linux:x86_64|Linux:amd64) RELEASE_TARGET="x86_64-unknown-linux-musl" ;;
  Linux:aarch64|Linux:arm64) RELEASE_TARGET="aarch64-unknown-linux-musl" ;;
  *) RELEASE_TARGET="" ;;
esac

rc=0; [[ -n "${RELEASE_TARGET}" ]] || rc=1
check "test runs on a supported release target" "${rc}"

RUNTIME_ASSET="vibeguard-runtime-${RELEASE_TARGET}"
cp "${REPO_DIR}/vibeguard-runtime/target/debug/vibeguard-runtime" \
  "${WORK}/release-assets/${RUNTIME_ASSET}"
chmod +x "${WORK}/release-assets/${RUNTIME_ASSET}"
(
  cd "${WORK}/release-assets"
  sha256sum "${PAYLOAD_ASSET}" "${RUNTIME_ASSET}" | sort -k2,2 > SHA256SUMS
)

header "stub network tools"

NETWORK_SENTINEL="${WORK}/network-access-attempted"
mkdir -p "${WORK}/fake-bin"

cat > "${WORK}/fake-bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >> "${VIBEGUARD_TEST_NETWORK_SENTINEL:?}"
url="${!#}"
dest=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then
    dest="$2"
  fi
  shift
done
[[ -n "${dest}" && -n "${VIBEGUARD_TEST_RELEASE_DIR:-}" ]] || exit 1
basename="$(basename "${url}")"
[[ -f "${VIBEGUARD_TEST_RELEASE_DIR}/${basename}" ]] || exit 1
cp "${VIBEGUARD_TEST_RELEASE_DIR}/${basename}" "${dest}"
SH
chmod +x "${WORK}/fake-bin/curl"

cat > "${WORK}/fake-bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != "release" || "${2:-}" != "download" ]]; then
  exit 1
fi
shift 2
download_dir=""
patterns=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) download_dir="$2"; shift 2 ;;
    --pattern) patterns+=("$2"); shift 2 ;;
    --repo) shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "${download_dir}" && -n "${VIBEGUARD_TEST_RELEASE_DIR:-}" ]] || exit 1
mkdir -p "${download_dir}"
for pattern in "${patterns[@]}"; do
  [[ -f "${VIBEGUARD_TEST_RELEASE_DIR}/${pattern}" ]] || exit 1
  cp "${VIBEGUARD_TEST_RELEASE_DIR}/${pattern}" "${download_dir}/${pattern}"
done
SH
chmod +x "${WORK}/fake-bin/gh"

cat > "${WORK}/fake-bin/launchctl" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "print" ]] && exit 113
exit 0
SH
chmod +x "${WORK}/fake-bin/launchctl"

cat > "${WORK}/fake-bin/systemctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "${WORK}/fake-bin/systemctl"

header "one-command install"

mkdir -p "${WORK}/home"
install_out="$(
  cd "${REPO_DIR}" \
    && HOME="${WORK}/home" \
      PATH="${WORK}/fake-bin:${PATH}" \
      VIBEGUARD_INSTALL_VERSION="${VERSION}" \
      VIBEGUARD_TEST_RELEASE_DIR="${WORK}/release-assets" \
      VIBEGUARD_TEST_NETWORK_SENTINEL="${NETWORK_SENTINEL}" \
      bash "${REPO_DIR}/install.sh" 2>&1
)" || rc=$?
rc=${rc:-0}
if [[ "${rc}" -ne 0 ]]; then
  printf '%s\n' "${install_out}" >&2
fi
check "install.sh completes with a local release payload" "${rc}"

rc=0
[[ -f "${WORK}/home/.vibeguard/installed/bin/vibeguard-runtime" ]] || rc=1
check "installed runtime binary exists" "${rc}"

set +e
printf '\nResults: %d passed, %d failed, %d total\n' "${PASS}" "${FAIL}" "${TOTAL}"
exit "${FAIL}"

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
TEST_HOME="${WORK}/home"

VERSION="$(tr -d '[:space:]' < "${REPO_DIR}/vibeguard-runtime/VERSION")"

header "build payload release asset"

mkdir -p "${WORK}/release-assets"
build_out="$(bash "${BUILD_PAYLOAD}" --output "${WORK}/release-assets" 2>&1)"
rc=$?
check "build-payload.sh succeeds" "${rc}"
PAYLOAD_ASSET="vibeguard-payload-${VERSION}.tar.gz"
rc=0; [[ -f "${WORK}/release-assets/${PAYLOAD_ASSET}" ]] || rc=1
check "payload archive exists" "${rc}"
cp "${REPO_DIR}/install.sh" "${WORK}/release-assets/install.sh"

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

sha256_for_test() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@"
  else
    shasum -a 256 "$@"
  fi
}

(
  cd "${WORK}/release-assets"
  sha256_for_test "${PAYLOAD_ASSET}" "${RUNTIME_ASSET}" | sort -k2,2 > SHA256SUMS
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
[[ -n "${VIBEGUARD_TEST_RELEASE_DIR:-}" ]] || exit 1
basename="$(basename "${url}")"
[[ -f "${VIBEGUARD_TEST_RELEASE_DIR}/${basename}" ]] || exit 1
if [[ -z "${dest}" ]]; then
  [[ "${VIBEGUARD_TEST_FAIL_STDOUT_DOWNLOAD:-0}" != "1" ]] || exit 22
  command cat "${VIBEGUARD_TEST_RELEASE_DIR}/${basename}"
else
  cp "${VIBEGUARD_TEST_RELEASE_DIR}/${basename}" "${dest}"
fi
SH
chmod +x "${WORK}/fake-bin/curl"

cat > "${WORK}/fake-bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "attestation" && "${2:-}" == "verify" && "${3:-}" == "--help" ]]; then
  exit 0
fi
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
  exit 0
fi
if [[ "${1:-}" == "attestation" && "${2:-}" == "verify" ]]; then
  [[ "${VIBEGUARD_TEST_ATTESTATION_OK:-1}" == "1" ]]
  exit
fi
[[ "${1:-}" == "release" && "${2:-}" == "download" ]] || exit 1
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
if [[ "${1:-}" == "--user" && ( "${2:-}" == "is-active" || "${2:-}" == "is-enabled" ) ]]; then
  exit 1
fi
exit 0
SH
chmod +x "${WORK}/fake-bin/systemctl"

header "one-command install"

mkdir -p "${TEST_HOME}"
install_out="$(
  cd "${REPO_DIR}" \
    && HOME="${TEST_HOME}" \
      PATH="${WORK}/fake-bin:${PATH}" \
      VIBEGUARD_TEST_RELEASE_DIR="${WORK}/release-assets" \
      VIBEGUARD_TEST_NETWORK_SENTINEL="${NETWORK_SENTINEL}" \
      bash -o pipefail -c \
        'curl -fsSL https://raw.githubusercontent.com/majiayu000/vibeguard/main/install.sh | bash -s -- --version "$1"' \
        _ "${VERSION}" 2>&1
)" || rc=$?
rc=${rc:-0}
if [[ "${rc}" -ne 0 ]]; then
  printf '%s\n' "${install_out}" >&2
fi
check "install.sh completes with a local release payload" "${rc}"

rc=0
[[ -f "${TEST_HOME}/.vibeguard/installed/bin/vibeguard-runtime" ]] || rc=1
check "installed runtime binary exists" "${rc}"

rc=0
[[ -L "${TEST_HOME}/.vibeguard/dist/current" ]] || rc=1
check "verified payload is persisted under dist/current" "${rc}"

doctor_rc=0
doctor_out="$(
  cd "${REPO_DIR}" \
    && HOME="${TEST_HOME}" \
      PATH="${WORK}/fake-bin:${PATH}" \
      VIBEGUARD_TEST_RELEASE_DIR="${WORK}/release-assets" \
      VIBEGUARD_TEST_NETWORK_SENTINEL="${NETWORK_SENTINEL}" \
      bash "${REPO_DIR}/install.sh" --version "${VERSION}" -- doctor --json 2>&1
)" || doctor_rc=$?
if [[ "${doctor_rc}" -ne 0 ]]; then
  printf '%s\n' "${doctor_out}" >&2
fi
check "forwarded doctor command preserves dispatcher position" "${doctor_rc}"

pack_rc=0
pack_out="$(
  cd "${REPO_DIR}" \
    && HOME="${TEST_HOME}" \
      PATH="${WORK}/fake-bin:${PATH}" \
      VIBEGUARD_TEST_RELEASE_DIR="${WORK}/release-assets" \
      VIBEGUARD_TEST_NETWORK_SENTINEL="${NETWORK_SENTINEL}" \
      bash "${REPO_DIR}/install.sh" --version "${VERSION}" -- \
        install --target claude-code --pack safe-bash --dry-run 2>&1
)" || pack_rc=$?
if [[ "${pack_rc}" -ne 0 ]]; then
  printf '%s\n' "${pack_out}" >&2
fi
check "forwarded guard-pack install omits setup-only --yes" "${pack_rc}"

header "dry-run and provenance boundaries"

DRY_RUN_HOME="${WORK}/dry-run-home"
mkdir -p "${DRY_RUN_HOME}"
dry_run_rc=0
dry_run_out="$(
  cd "${REPO_DIR}" \
    && HOME="${DRY_RUN_HOME}" \
      PATH="${WORK}/fake-bin:${PATH}" \
      VIBEGUARD_TEST_RELEASE_DIR="${WORK}/release-assets" \
      VIBEGUARD_TEST_NETWORK_SENTINEL="${NETWORK_SENTINEL}" \
      bash "${REPO_DIR}/install.sh" --version "${VERSION}" -- --dry-run 2>&1
)" || dry_run_rc=$?
if [[ "${dry_run_rc}" -ne 0 ]]; then
  printf '%s\n' "${dry_run_out}" >&2
fi
check "hosted installer dry-run succeeds" "${dry_run_rc}"

rc=0
[[ ! -e "${DRY_RUN_HOME}/.vibeguard/installed" ]] || rc=1
check "dry-run does not create an installed snapshot" "${rc}"

PROVENANCE_HOME="${WORK}/provenance-home"
mkdir -p "${PROVENANCE_HOME}"
provenance_rc=0
provenance_out="$(
  cd "${REPO_DIR}" \
    && HOME="${PROVENANCE_HOME}" \
      PATH="${WORK}/fake-bin:${PATH}" \
      VIBEGUARD_TEST_ATTESTATION_OK=0 \
      VIBEGUARD_TEST_RELEASE_DIR="${WORK}/release-assets" \
      VIBEGUARD_TEST_NETWORK_SENTINEL="${NETWORK_SENTINEL}" \
      bash "${REPO_DIR}/install.sh" --version "${VERSION}" \
        --require-provenance 2>&1
)" || provenance_rc=$?
rc=0
[[ "${provenance_rc}" -ne 0 ]] || rc=1
check "required provenance failure stops the installer" "${rc}"

rc=0
[[ ! -e "${PROVENANCE_HOME}/.vibeguard" ]] || rc=1
check "provenance failure creates no VibeGuard state" "${rc}"

PIPE_FAIL_HOME="${WORK}/pipe-fail-home"
mkdir -p "${PIPE_FAIL_HOME}"
pipe_fail_rc=0
pipe_fail_out="$(
  cd "${REPO_DIR}" \
    && HOME="${PIPE_FAIL_HOME}" \
      PATH="${WORK}/fake-bin:${PATH}" \
      VIBEGUARD_TEST_FAIL_STDOUT_DOWNLOAD=1 \
      VIBEGUARD_TEST_RELEASE_DIR="${WORK}/release-assets" \
      VIBEGUARD_TEST_NETWORK_SENTINEL="${NETWORK_SENTINEL}" \
      bash -o pipefail -c \
        'curl -fsSL https://raw.githubusercontent.com/majiayu000/vibeguard/main/install.sh | bash -s -- --version "$1"' \
        _ "${VERSION}" 2>&1
)" || pipe_fail_rc=$?
rc=0
[[ "${pipe_fail_rc}" -ne 0 ]] || rc=1
check "published pipefail form reports installer download failure" "${rc}"

network_rows_before="$(wc -l < "${NETWORK_SENTINEL}" | tr -d '[:space:]')"
invalid_version_rc=0
bash "${REPO_DIR}/install.sh" --version '1.2.3+bad..meta' >/dev/null 2>&1 \
  || invalid_version_rc=$?
network_rows_after="$(wc -l < "${NETWORK_SENTINEL}" | tr -d '[:space:]')"
rc=0
[[ "${invalid_version_rc}" -eq 64 && "${network_rows_before}" == "${network_rows_after}" ]] || rc=1
check "malformed build metadata fails before network access" "${rc}"

set +e
printf '\nResults: %d passed, %d failed, %d total\n' "${PASS}" "${FAIL}" "${TOTAL}"
exit "${FAIL}"

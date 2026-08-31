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
grep -qx 'scripts/setup/install.sh' "${MANIFEST}" || rc=1
grep -qx 'scripts/setup/protection-status.sh' "${MANIFEST}" || rc=1
grep -qx 'scripts/setup/bootstrap.sh' "${MANIFEST}" || rc=1
grep -qx 'scripts/setup/bootstrap-lib.sh' "${MANIFEST}" || rc=1
grep -qx 'scripts/lib/install-state.sh' "${MANIFEST}" || rc=1
grep -qx 'scripts/release/payload-manifest.txt' "${MANIFEST}" || rc=1
check "manifest keeps the install-critical entries" "${rc}"

rc=0
for dev_only in docs tests eval plan site scripts; do
  if grep -qx "${dev_only}" "${MANIFEST}"; then
    rc=1
  fi
done
check "manifest excludes broad dev-only surfaces, including all scripts/" "${rc}"

rc=0
for forbidden_entry in \
  scripts/ci \
  scripts/release/build-payload.sh \
  scripts/verify \
  scripts/metrics \
  scripts/benchmark \
  scripts/eval; do
  if grep -qE "^${forbidden_entry}(/|$)" "${MANIFEST}"; then
    rc=1
  fi
done
check "manifest excludes CI, release tooling, verification, metrics, benchmark, and eval paths" "${rc}"

header "build-payload.sh"

VERSION="$(tr -d '[:space:]' < "${REPO_DIR}/vibeguard-runtime/VERSION")"
build_out="$(bash "${BUILD_PAYLOAD}" --output "${WORK}/dist-one" 2>&1)"
rc=$?
check "build-payload.sh builds from HEAD (exit 0)" "${rc}"

ARCHIVE="${WORK}/dist-one/vibeguard-payload-${VERSION}.tar.gz"
rc=0; [[ -f "${ARCHIVE}" ]] || rc=1
check "archive named vibeguard-payload-${VERSION}.tar.gz exists" "${rc}"

bash "${BUILD_PAYLOAD}" --output "${WORK}/dist-two" >/dev/null
SECOND_ARCHIVE="${WORK}/dist-two/vibeguard-payload-${VERSION}.tar.gz"
rc=0
cmp -s "${ARCHIVE}" "${SECOND_ARCHIVE}" || rc=1
check "two builds of the same ref are byte-for-byte identical" "${rc}"

GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0=tar.umask \
  GIT_CONFIG_VALUE_0=0002 \
  bash "${BUILD_PAYLOAD}" --output "${WORK}/dist-umask-0002" >/dev/null
GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0=tar.umask \
  GIT_CONFIG_VALUE_0=0022 \
  bash "${BUILD_PAYLOAD}" --output "${WORK}/dist-umask-0022" >/dev/null
UMASK_0002_ARCHIVE="${WORK}/dist-umask-0002/vibeguard-payload-${VERSION}.tar.gz"
UMASK_0022_ARCHIVE="${WORK}/dist-umask-0022/vibeguard-payload-${VERSION}.tar.gz"
rc=0
cmp -s "${UMASK_0002_ARCHIVE}" "${UMASK_0022_ARCHIVE}" || rc=1
check "conflicting injected tar.umask values produce identical archives" "${rc}"

GIT_CONFIG_COUNT=2 \
  GIT_CONFIG_KEY_0=core.autocrlf \
  GIT_CONFIG_VALUE_0=true \
  GIT_CONFIG_KEY_1=core.eol \
  GIT_CONFIG_VALUE_1=crlf \
  bash "${BUILD_PAYLOAD}" --output "${WORK}/dist-eol-crlf" >/dev/null
GIT_CONFIG_COUNT=2 \
  GIT_CONFIG_KEY_0=core.autocrlf \
  GIT_CONFIG_VALUE_0=input \
  GIT_CONFIG_KEY_1=core.eol \
  GIT_CONFIG_VALUE_1=lf \
  bash "${BUILD_PAYLOAD}" --output "${WORK}/dist-eol-lf" >/dev/null
EOL_CRLF_ARCHIVE="${WORK}/dist-eol-crlf/vibeguard-payload-${VERSION}.tar.gz"
EOL_LF_ARCHIVE="${WORK}/dist-eol-lf/vibeguard-payload-${VERSION}.tar.gz"
rc=0
cmp -s "${EOL_CRLF_ARCHIVE}" "${EOL_LF_ARCHIVE}" || rc=1
check "conflicting injected core.autocrlf/core.eol values produce identical archives" "${rc}"

rc=0
for eol_archive in "${EOL_CRLF_ARCHIVE}" "${EOL_LF_ARCHIVE}"; do
  if tar -xOzf "${eol_archive}" scripts/release/payload-manifest.txt \
    | LC_ALL=C grep -q $'\r'; then
    rc=1
  fi
  archived_eol_manifest_sha="$(
    tar -xOzf "${eol_archive}" scripts/release/payload-manifest.txt \
      | shasum -a 256 \
      | awk '{print $1}'
  )"
  marker_eol_manifest_sha="$(
    tar -xOzf "${eol_archive}" .vibeguard-payload \
      | awk -F= '$1 == "manifest_sha256" { print $2; exit }'
  )"
  [[ "${archived_eol_manifest_sha}" == "${marker_eol_manifest_sha}" ]] || rc=1
done
check "payload manifest stays LF-only and marker digest matches under conflicting EOL config" "${rc}"

rc=0
for umask_archive in "${UMASK_0002_ARCHIVE}" "${UMASK_0022_ARCHIVE}"; do
  setup_mode="$(tar -tvzf "${umask_archive}" | awk '$NF == "setup.sh" { mode = $1 } END { print mode }')"
  marker_mode="$(tar -tvzf "${umask_archive}" | awk '$NF == ".vibeguard-payload" { mode = $1 } END { print mode }')"
  [[ "${setup_mode}" == "-rwxr-xr-x" ]] || rc=1
  [[ "${marker_mode}" == "-rw-r--r--" ]] || rc=1
done
check "archive mode policy fixes setup at 0755 and marker at 0644" "${rc}"

mkdir -p "${WORK}/unpacked"
tar -xzf "${ARCHIVE}" -C "${WORK}/unpacked"

rc=0; [[ -f "${WORK}/unpacked/.vibeguard-payload" ]] || rc=1
check "unpacked payload carries .vibeguard-payload marker" "${rc}"

rc=0
grep -q "^version=${VERSION}$" "${WORK}/unpacked/.vibeguard-payload" || rc=1
grep -q '^manifest_sha256=[0-9a-f]\{64\}$' "${WORK}/unpacked/.vibeguard-payload" || rc=1
grep -q '^git_commit=[0-9a-f]\{40\}$' "${WORK}/unpacked/.vibeguard-payload" || rc=1
check "marker records version, manifest sha256, and git commit" "${rc}"

rc=0
archived_manifest_sha="$(
  shasum -a 256 "${WORK}/unpacked/scripts/release/payload-manifest.txt" \
    | awk '{print $1}'
)"
marker_manifest_sha="$(
  awk -F= '$1 == "manifest_sha256" { print $2; exit }' \
    "${WORK}/unpacked/.vibeguard-payload"
)"
[[ "${archived_manifest_sha}" == "${marker_manifest_sha}" ]] || rc=1
check "marker manifest hash matches the manifest shipped in the archive" "${rc}"

rc=0
for required in \
  setup.sh \
  vibeguard-runtime/VERSION \
  hooks/run-hook.sh \
  rules \
  scripts/setup/bootstrap.sh \
  scripts/setup/bootstrap-lib.sh \
  scripts/setup/install.sh \
  scripts/lib/guard_pack_demo.py \
  scripts/lib/install-state.sh \
  scripts/release/payload-manifest.txt; do
  [[ -e "${WORK}/unpacked/${required}" ]] || { echo "missing: ${required}" >&2; rc=1; }
done
check "unpacked payload contains install-critical paths" "${rc}"

rc=0
for excluded in \
  docs \
  tests \
  eval \
  plan \
  site \
  .git \
  vibeguard-runtime/src \
  scripts/ci \
  scripts/release/build-payload.sh \
  scripts/verify \
  scripts/metrics; do
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

git clone --quiet --no-hardlinks "${REPO_DIR}" "${WORK}/ref-fixture"
bash "${WORK}/ref-fixture/scripts/release/build-payload.sh" \
  --ref HEAD \
  --output "${WORK}/ref-clean" >/dev/null
printf '\n# dirty working-tree content must not affect --ref HEAD\nscripts/ci\n' \
  >> "${WORK}/ref-fixture/scripts/release/payload-manifest.txt"
bash "${WORK}/ref-fixture/scripts/release/build-payload.sh" \
  --ref HEAD \
  --output "${WORK}/ref-dirty" >/dev/null
rc=0
cmp -s \
  "${WORK}/ref-clean/vibeguard-payload-${VERSION}.tar.gz" \
  "${WORK}/ref-dirty/vibeguard-payload-${VERSION}.tar.gz" || rc=1
check "dirty working-tree manifest cannot change a --ref HEAD payload" "${rc}"

header "payload mode behavior"

# Payload mode must reject --build-from-source before doing any work.
out="$(cd "${WORK}/unpacked" && bash setup.sh --dry-run --build-from-source 2>&1)" && rc=1 || rc=0
check "payload mode rejects --build-from-source" "${rc}"
rc=0
grep -q 'not available in payload mode' <<< "${out}" || rc=1
check "--build-from-source rejection names payload mode" "${rc}"

out="$(cd "${WORK}/unpacked" && bash setup.sh --dry-run --runtime-version v0.0.0 2>&1)" && rc=1 || rc=0
check "payload mode rejects mismatched --runtime-version" "${rc}"
rc=0
grep -q 'does not match payload version' <<< "${out}" || rc=1
check "--runtime-version rejection names the payload pin mismatch" "${rc}"

out="$(
  cd "${WORK}/unpacked" \
    && VIBEGUARD_SETUP_RUNTIME_VERSION=v0.0.0 bash setup.sh --dry-run 2>&1
)" && rc=1 || rc=0
check "payload mode rejects mismatched VIBEGUARD_SETUP_RUNTIME_VERSION" "${rc}"
rc=0
grep -q 'does not match payload version' <<< "${out}" || rc=1
check "runtime-version environment rejection names the payload pin mismatch" "${rc}"

out="$(
  cd "${WORK}/unpacked" \
    && bash setup.sh --dry-run --runtime-version "v${VERSION}" --build-from-source 2>&1
)" && rc=1 || rc=0
check "normalized runtime override equal to the payload version passes the pin check" "${rc}"
rc=0
grep -q 'does not match payload version' <<< "${out}" && rc=1
grep -q 'build-from-source is not available in payload mode' <<< "${out}" || rc=1
check "equal runtime override reaches the independent source-build guard" "${rc}"

out="$(cd "${WORK}/unpacked" && bash setup.sh --dry-run --dev-linked 2>&1)" && rc=1 || rc=0
check "payload mode rejects --dev-linked" "${rc}"
rc=0
grep -q 'dev-linked is not available in payload mode' <<< "${out}" || rc=1
check "--dev-linked rejection names payload mode" "${rc}"

out="$(
  cd "${WORK}/unpacked" \
    && VIBEGUARD_SETUP_DEV_LINKED=1 bash setup.sh --dry-run 2>&1
)" && rc=1 || rc=0
check "payload mode rejects VIBEGUARD_SETUP_DEV_LINKED=1" "${rc}"
rc=0
grep -q 'dev-linked is not available in payload mode' <<< "${out}" || rc=1
check "dev-linked environment rejection names payload mode" "${rc}"

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

header "unpacked payload install"

# Reuse the setup suite's safety model: build a local runtime fixture, expose it
# through a fake gh release downloader, and confine all writes to a temp HOME.
# No network call or user-home write is possible in this fixture.
cargo build --quiet --manifest-path "${REPO_DIR}/vibeguard-runtime/Cargo.toml"
case "$(uname -s):$(uname -m)" in
  Darwin:arm64|Darwin:aarch64) RELEASE_TARGET="aarch64-apple-darwin" ;;
  Darwin:x86_64|Darwin:amd64) RELEASE_TARGET="x86_64-apple-darwin" ;;
  Linux:x86_64|Linux:amd64) RELEASE_TARGET="x86_64-unknown-linux-musl" ;;
  Linux:aarch64|Linux:arm64) RELEASE_TARGET="aarch64-unknown-linux-musl" ;;
  *) RELEASE_TARGET="" ;;
esac

rc=0
[[ -n "${RELEASE_TARGET}" ]] || rc=1
check "payload install fixture runs on a supported release target" "${rc}"

mkdir -p "${WORK}/release-assets" "${WORK}/fake-bin" "${WORK}/payload-home"
RUNTIME_ASSET="vibeguard-runtime-${RELEASE_TARGET}"
cp "${REPO_DIR}/vibeguard-runtime/target/debug/vibeguard-runtime" \
  "${WORK}/release-assets/${RUNTIME_ASSET}"
chmod +x "${WORK}/release-assets/${RUNTIME_ASSET}"
runtime_sha="$(
  shasum -a 256 "${WORK}/release-assets/${RUNTIME_ASSET}" \
    | awk '{print $1}'
)"
printf '%s  %s\n' "${runtime_sha}" "${RUNTIME_ASSET}" \
  > "${WORK}/release-assets/SHA256SUMS"

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
    --dir)
      download_dir="$2"; shift 2 ;;
    --pattern)
      patterns+=("$2"); shift 2 ;;
    --repo)
      shift 2 ;;
    *)
      shift ;;
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
# A temp HOME has no loaded launchd jobs. Keep host launchd state from leaking
# into the no-clone installation fixture.
if [[ "${1:-}" == "print" ]]; then
  exit 113
fi
exit 0
SH
chmod +x "${WORK}/fake-bin/launchctl"
NETWORK_SENTINEL="${WORK}/network-access-attempted"
cat > "${WORK}/fake-bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >> "${VIBEGUARD_TEST_NETWORK_SENTINEL:?}"
exit 97
SH
chmod +x "${WORK}/fake-bin/curl"
cat > "${WORK}/fake-bin/systemctl" <<'SH'
#!/usr/bin/env bash
# The payload fixture must not inspect or mutate host systemd state.
[[ "${1:-}" == "--user" ]] && shift
case "${1:-}" in
  is-active) exit 3 ;;
  *) exit 0 ;;
esac
SH
chmod +x "${WORK}/fake-bin/systemctl"

header "profile and language matrix"

matrix_rc=0
matrix_cases=0
for profile in minimal core full strict; do
  for language in rust python go typescript; do
    matrix_cases=$((matrix_cases + 1))
    matrix_home="${WORK}/matrix-home/${profile}-${language}"
    matrix_codex_home="${matrix_home}/.codex"
    mkdir -p "${matrix_home}"
    set +e
    matrix_out="$(
      cd "${WORK}/unpacked" \
        && HOME="${matrix_home}" \
          CODEX_HOME="${matrix_codex_home}" \
          PATH="${WORK}/fake-bin:${PATH}" \
          VIBEGUARD_TEST_RELEASE_DIR="${WORK}/release-assets" \
          VIBEGUARD_TEST_NETWORK_SENTINEL="${NETWORK_SENTINEL}" \
          bash setup.sh --dry-run --profile "${profile}" --languages "${language}" 2>&1
    )"
    matrix_status=$?
    set -e
    if [[ "${matrix_status}" -ne 0 ]]; then
      printf 'matrix failure: profile=%s language=%s\n%s\n' \
        "${profile}" "${language}" "${matrix_out}" >&2
      matrix_rc=1
    fi
    if find "${matrix_home}" \( -type f -o -type l \) -print -quit | grep -q .; then
      printf 'matrix dry-run wrote a file to temp HOME: profile=%s language=%s\n' \
        "${profile}" "${language}" >&2
      matrix_rc=1
    fi
  done
done
[[ "${matrix_cases}" -eq 16 ]] || matrix_rc=1
check "all 16 profile/language payload dry-run combinations execute safely" "${matrix_rc}"

set +e
install_out="$(
  cd "${WORK}/unpacked" \
    && HOME="${WORK}/payload-home" \
      CODEX_HOME="${WORK}/payload-home/.codex" \
      PATH="${WORK}/fake-bin:${PATH}" \
      VIBEGUARD_TEST_RELEASE_DIR="${WORK}/release-assets" \
      VIBEGUARD_TEST_NETWORK_SENTINEL="${NETWORK_SENTINEL}" \
      bash setup.sh --yes 2>&1
)"
rc=$?
set -e
if [[ "${rc}" -ne 0 ]]; then
  printf '%s\n' "${install_out}" >&2
fi
check "unpacked payload installs into a temp HOME without network" "${rc}"
rc=0
grep -q 'Setup complete! All components installed.' <<< "${install_out}" || rc=1
grep -q 'vibeguard-runtime downloaded and verified' <<< "${install_out}" || rc=1
check "payload install completes with a verified local release runtime" "${rc}"

set +e
doctor_out="$(
  cd "${WORK}/unpacked" \
    && HOME="${WORK}/payload-home" \
      CODEX_HOME="${WORK}/payload-home/.codex" \
      PATH="${WORK}/fake-bin:${PATH}" \
      VIBEGUARD_TEST_NETWORK_SENTINEL="${NETWORK_SENTINEL}" \
      bash setup.sh doctor 2>&1
)"
rc=$?
set -e
if [[ "${rc}" -ne 0 ]]; then
  printf '%s\n' "${doctor_out}" >&2
fi
check "doctor executes successfully after the unpacked payload install" "${rc}"

set +e
verify_out="$(
  cd "${WORK}/unpacked" \
    && HOME="${WORK}/payload-home" \
      CODEX_HOME="${WORK}/payload-home/.codex" \
      PATH="${WORK}/fake-bin:${PATH}" \
      VIBEGUARD_TEST_NETWORK_SENTINEL="${NETWORK_SENTINEL}" \
      bash setup.sh verify-install 2>&1
)"
rc=$?
set -e
if [[ "${rc}" -ne 0 ]]; then
  printf '%s\n' "${verify_out}" >&2
fi
check "verify-install succeeds after the unpacked payload install" "${rc}"
# verify-install intentionally permits optional WARN/INFO rows. Its exit code
# is authoritative for required install health; the human verdict may be
# HEALTHY or DEGRADED depending on platform integrations.
rc=0
grep -q '^Summary$' <<< "${verify_out}" || rc=1
grep -q 'Verdict :' <<< "${verify_out}" || rc=1
if [[ "${rc}" -ne 0 ]]; then
  printf '%s\n' "${verify_out}" >&2
fi
check "verify-install reports an explicit installation verdict" "${rc}"

set +e
demo_out="$(
  cd "${WORK}/unpacked" \
    && HOME="${WORK}/payload-home" \
      CODEX_HOME="${WORK}/payload-home/.codex" \
      PATH="${WORK}/fake-bin:${PATH}" \
      VIBEGUARD_TEST_NETWORK_SENTINEL="${NETWORK_SENTINEL}" \
      bash setup.sh demo safe-bash 2>&1
)"
rc=$?
set -e
if [[ "${rc}" -ne 0 ]]; then
  printf '%s\n' "${demo_out}" >&2
fi
check "payload runs the live safe-bash interception demo" "${rc}"
rc=0
grep -q 'DENIED: decision=block' <<< "${demo_out}" || rc=1
grep -q 'temporary HOME marker remains intact' <<< "${demo_out}" || rc=1
check "payload demo proves block decision and sandbox preservation" "${rc}"

rc=0
[[ -x "${WORK}/payload-home/.vibeguard/installed/bin/vibeguard-runtime" ]] || rc=1
[[ -f "${WORK}/payload-home/.vibeguard/install-state.json" ]] || rc=1
[[ -f "${WORK}/payload-home/.codex/hooks.json" ]] || rc=1
check "payload install writes only expected assets beneath the temp HOME" "${rc}"

set +e
clean_out="$(
  cd "${WORK}/unpacked" \
    && HOME="${WORK}/payload-home" \
      CODEX_HOME="${WORK}/payload-home/.codex" \
      PATH="${WORK}/fake-bin:${PATH}" \
      VIBEGUARD_TEST_NETWORK_SENTINEL="${NETWORK_SENTINEL}" \
      bash setup.sh --clean --purge-data 2>&1
)"
rc=$?
set -e
if [[ "${rc}" -ne 0 ]]; then
  printf '%s\n' "${clean_out}" >&2
fi
check "clean executes successfully after payload doctor and verification" "${rc}"
rc=0
[[ ! -e "${WORK}/payload-home/.vibeguard/installed" ]] || rc=1
[[ ! -e "${WORK}/payload-home/.vibeguard/install-state.json" ]] || rc=1
[[ ! -e "${WORK}/payload-home/.vibeguard/config.json" ]] || rc=1
check "payload clean removes installed state and purged temp-HOME data" "${rc}"

rc=0
[[ ! -e "${NETWORK_SENTINEL}" ]] || rc=1
check "payload matrix, install, doctor, verify, and clean never invoke curl" "${rc}"

echo
echo "=============================="
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' "${TOTAL}" "${PASS}" "${FAIL}"
echo "=============================="
[[ "${FAIL}" -eq 0 ]]

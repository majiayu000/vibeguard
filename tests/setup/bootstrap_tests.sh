header "pinned payload bootstrap"

BOOTSTRAP="${REPO_DIR}/scripts/setup/bootstrap.sh"
BOOTSTRAP_LIB="${REPO_DIR}/scripts/setup/bootstrap-lib.sh"
BOOTSTRAP_VERSION="$(tr -d '[:space:]' < "${REPO_DIR}/vibeguard-runtime/VERSION")"
BOOTSTRAP_ASSET="vibeguard-payload-${BOOTSTRAP_VERSION}.tar.gz"
BOOTSTRAP_RELEASE="${TMP_HOME}/bootstrap-release-good"

assert_cmd "bootstrap entrypoint exists and is executable" test -x "${BOOTSTRAP}"
assert_cmd "bootstrap helper exists" test -f "${BOOTSTRAP_LIB}"
assert_cmd "bootstrap entrypoint syntax is correct" bash -n "${BOOTSTRAP}"
assert_cmd "bootstrap helper syntax is correct" bash -n "${BOOTSTRAP_LIB}"
assert_cmd "bootstrap entrypoint stays below focused limit" bash -c \
  'test "$(wc -l < "$1")" -lt 400' _ "${BOOTSTRAP}"
assert_cmd "bootstrap helper stays below focused limit" bash -c \
  'test "$(wc -l < "$1")" -lt 400' _ "${BOOTSTRAP_LIB}"

mkdir -p "${BOOTSTRAP_RELEASE}"
cp "${TEST_RELEASE_DIR}"/vibeguard-runtime-* "${BOOTSTRAP_RELEASE}/"
cp "${TEST_RELEASE_DIR}/vibeguard-runtime-releases.json" "${BOOTSTRAP_RELEASE}/"
bash "${REPO_DIR}/scripts/release/build-payload.sh" \
  --output "${BOOTSTRAP_RELEASE}" >/dev/null
{
  for release_asset in "${BOOTSTRAP_RELEASE}"/vibeguard-runtime-*; do
    release_name="${release_asset##*/}"
    release_sha="$(shasum -a 256 "${release_asset}" | awk '{print $1}')"
    printf '%s  %s\n' "${release_sha}" "${release_name}"
  done
  payload_sha="$(shasum -a 256 "${BOOTSTRAP_RELEASE}/${BOOTSTRAP_ASSET}" | awk '{print $1}')"
  printf '%s  %s\n' "${payload_sha}" "${BOOTSTRAP_ASSET}"
} | LC_ALL=C sort -k2,2 > "${BOOTSTRAP_RELEASE}/SHA256SUMS"
awk -v asset="${BOOTSTRAP_ASSET}" '
  $2 == asset { print "0000000000000000000000000000000000000000000000000000000000000000  " asset; next }
  { print }
' "${BOOTSTRAP_RELEASE}/SHA256SUMS" > "${BOOTSTRAP_RELEASE}/SHA256SUMS.bad"

bootstrap_base_env=(
  VIBEGUARD_TEST_DOWNLOAD_FAIL=0
  VIBEGUARD_TEST_GH_FAIL=0
  VIBEGUARD_TEST_BAD_SHA=0
  VIBEGUARD_TEST_ATTESTATION_AVAILABLE=0
  VIBEGUARD_TEST_GH_AUTH_OK=0
  VIBEGUARD_TEST_ATTESTATION_OK=0
)

missing_home="${TMP_HOME}/bootstrap-missing-version-home"
mkdir -p "${missing_home}"
missing_rc=0
missing_out="$(
  env "${bootstrap_base_env[@]}" HOME="${missing_home}" \
    bash "${BOOTSTRAP}" 2>&1
)" || missing_rc=$?
assert_cmd "bootstrap requires an exact version" test "${missing_rc}" -eq 64
assert_contains "${missing_out}" "--version is required" "missing version reports the closed pin requirement"
assert_cmd "missing version creates no VibeGuard state" test ! -e "${missing_home}/.vibeguard"

latest_home="${TMP_HOME}/bootstrap-latest-home"
mkdir -p "${latest_home}"
latest_rc=0
latest_out="$(
  env "${bootstrap_base_env[@]}" HOME="${latest_home}" \
    bash "${BOOTSTRAP}" --version latest 2>&1
)" || latest_rc=$?
assert_cmd "bootstrap rejects floating latest" test "${latest_rc}" -eq 64
assert_contains "${latest_out}" "invalid exact version" "floating version reports an exact-version error"
assert_cmd "floating version creates no VibeGuard state" test ! -e "${latest_home}/.vibeguard"

assert_cmd "SemVer parser accepts exact release and prerelease forms" bash -c '
  source "$1"
  bootstrap_validate_version "0.0.0"
  bootstrap_validate_version "1.2.3-0"
  bootstrap_validate_version "1.2.3-alpha.1+build.01"
' _ "${BOOTSTRAP_LIB}"

invalid_semver_index=0
for invalid_semver in \
  01.2.3 \
  1.02.3 \
  1.2.03 \
  1.2.3-01 \
  1.2.3-alpha..1 \
  1.2.3-alpha. \
  1.2.3-.alpha \
  1.2.3+build..1 \
  1.2.3+build. \
  1.2.3+.build; do
  invalid_semver_index=$((invalid_semver_index + 1))
  invalid_semver_home="${TMP_HOME}/bootstrap-invalid-semver-${invalid_semver_index}"
  mkdir -p "${invalid_semver_home}"
  invalid_semver_rc=0
  invalid_semver_out="$(
    env "${bootstrap_base_env[@]}" HOME="${invalid_semver_home}" \
      bash "${BOOTSTRAP}" --version "${invalid_semver}" 2>&1
  )" || invalid_semver_rc=$?
  assert_cmd "bootstrap rejects invalid exact SemVer ${invalid_semver}" \
    test "${invalid_semver_rc}" -eq 64
  assert_contains "${invalid_semver_out}" "invalid exact version" \
    "invalid SemVer ${invalid_semver} reports the exact-version contract"
  assert_cmd "invalid SemVer ${invalid_semver} creates zero state" \
    test ! -e "${invalid_semver_home}/.vibeguard"
done

unknown_rc=0
unknown_out="$(
  env "${bootstrap_base_env[@]}" HOME="${latest_home}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" --repo attacker/example 2>&1
)" || unknown_rc=$?
assert_cmd "bootstrap rejects undeclared trust-boundary arguments" test "${unknown_rc}" -eq 64
assert_contains "${unknown_out}" "unknown bootstrap argument" "unknown argument fails visibly"

verified_home="${TMP_HOME}/bootstrap-verified-home"
mkdir -p "${verified_home}"
verified_rc=0
verified_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${verified_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${BOOTSTRAP_RELEASE}" \
    VIBEGUARD_TEST_ATTESTATION_AVAILABLE=1 \
    VIBEGUARD_TEST_GH_AUTH_OK=1 \
    VIBEGUARD_TEST_ATTESTATION_OK=1 \
    bash "${BOOTSTRAP}" --version "v${BOOTSTRAP_VERSION}" \
      --require-provenance -- --dry-run --yes 2>&1
)" || verified_rc=$?
assert_cmd "verified bootstrap executes payload setup" test "${verified_rc}" -eq 0
assert_contains "${verified_out}" "provenance=verified-provenance" "verified bootstrap reports provenance status"
assert_cmd "verified bootstrap installs an immutable version directory" \
  test -d "${verified_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}"
assert_cmd "verified bootstrap atomically selects the pinned version" bash -c \
  'test -L "$1" && test "$(readlink "$1")" = "$2"' _ \
  "${verified_home}/.vibeguard/dist/current" "${BOOTSTRAP_VERSION}"
assert_cmd "payload setup dry-run leaves no active installed snapshot" \
  test ! -e "${verified_home}/.vibeguard/installed"

repeat_rc=0
repeat_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${verified_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${BOOTSTRAP_RELEASE}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --dry-run --yes 2>&1
)" || repeat_rc=$?
assert_cmd "bootstrap refuses to overwrite an existing dist version" test "${repeat_rc}" -ne 0
assert_contains "${repeat_out}" "distribution version already exists" "version conflict fails visibly"
assert_cmd "version conflict preserves the selected current target" bash -c \
  'test "$(readlink "$1")" = "$2"' _ \
  "${verified_home}/.vibeguard/dist/current" "${BOOTSTRAP_VERSION}"

fallback_home="${TMP_HOME}/bootstrap-curl-fallback-home"
fallback_log="${TMP_HOME}/bootstrap-curl-fallback.log"
mkdir -p "${fallback_home}"
: > "${fallback_log}"
fallback_rc=0
fallback_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${fallback_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${BOOTSTRAP_RELEASE}" \
    VIBEGUARD_TEST_GH_FAIL=1 \
    VIBEGUARD_TEST_DOWNLOAD_LOG="${fallback_log}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --dry-run --yes 2>&1
)" || fallback_rc=$?
assert_cmd "bootstrap falls back from gh to curl" test "${fallback_rc}" -eq 0
assert_contains "${fallback_out}" "provenance=checksum-only" "optional unavailable provenance is explicit"
assert_cmd "curl fallback downloads only named release files" bash -c \
  'grep -q "asset=vibeguard-payload-" "$1" && grep -q "asset=SHA256SUMS" "$1"' _ \
  "${fallback_log}"

switch_home="${TMP_HOME}/bootstrap-existing-current-home"
mkdir -p "${switch_home}/.vibeguard/dist/old"
ln -s old "${switch_home}/.vibeguard/dist/current"
switch_rc=0
switch_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${switch_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${BOOTSTRAP_RELEASE}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --dry-run --yes 2>&1
)" || switch_rc=$?
assert_cmd "bootstrap replaces current symlink without following its directory target" \
  test "${switch_rc}" -eq 0
assert_contains "${switch_out}" "provenance=checksum-only" "existing-current switch completes verification"
assert_cmd "existing current atomically switches from old to the exact version" bash -c \
  'test -L "$1" && test "$(readlink "$1")" = "$2"' _ \
  "${switch_home}/.vibeguard/dist/current" "${BOOTSTRAP_VERSION}"
assert_cmd "BSD/GNU atomic switch leaves no temporary link inside old target" bash -c \
  'test -z "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit)"' _ \
  "${switch_home}/.vibeguard/dist/old"

required_home="${TMP_HOME}/bootstrap-required-provenance-home"
mkdir -p "${required_home}"
required_rc=0
required_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${required_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${BOOTSTRAP_RELEASE}" \
    VIBEGUARD_TEST_GH_FAIL=1 \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" \
      --require-provenance -- --dry-run --yes 2>&1
)" || required_rc=$?
assert_cmd "required provenance fails closed when unavailable" test "${required_rc}" -ne 0
assert_contains "${required_out}" "provenance is required but unavailable" "required provenance failure is actionable"
assert_cmd "required provenance failure creates no version or current" bash -c \
  'test ! -e "$1" && test ! -L "$1" && test ! -e "$2"' _ \
  "${required_home}/.vibeguard/dist/current" \
  "${required_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}"

download_fail_home="${TMP_HOME}/bootstrap-download-failure-home"
mkdir -p "${download_fail_home}"
download_fail_rc=0
download_fail_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${download_fail_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${BOOTSTRAP_RELEASE}" \
    VIBEGUARD_TEST_DOWNLOAD_FAIL=1 \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --dry-run --yes 2>&1
)" || download_fail_rc=$?
assert_cmd "failed gh and curl downloads fail closed" test "${download_fail_rc}" -ne 0
assert_contains "${download_fail_out}" "release download failed" "download failure is actionable"
assert_cmd "download failure creates no version or current" bash -c \
  'test ! -e "$1" && test ! -L "$1" && test ! -e "$2"' _ \
  "${download_fail_home}/.vibeguard/dist/current" \
  "${download_fail_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}"

attestation_home="${TMP_HOME}/bootstrap-attestation-failure-home"
mkdir -p "${attestation_home}"
attestation_rc=0
attestation_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${attestation_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${BOOTSTRAP_RELEASE}" \
    VIBEGUARD_TEST_ATTESTATION_AVAILABLE=1 \
    VIBEGUARD_TEST_GH_AUTH_OK=1 \
    VIBEGUARD_TEST_ATTESTATION_OK=0 \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --dry-run --yes 2>&1
)" || attestation_rc=$?
assert_cmd "failed available attestation is never downgraded" test "${attestation_rc}" -ne 0
assert_contains "${attestation_out}" "provenance verification failed" "attestation failure is explicit"
assert_cmd "attestation failure creates no active selection" \
  test ! -e "${attestation_home}/.vibeguard/dist/current"

tampered_release="${TMP_HOME}/bootstrap-release-tampered"
mkdir -p "${tampered_release}"
cp "${BOOTSTRAP_RELEASE}/${BOOTSTRAP_ASSET}" "${tampered_release}/${BOOTSTRAP_ASSET}"
cp "${BOOTSTRAP_RELEASE}/SHA256SUMS" "${tampered_release}/SHA256SUMS"
printf 'tampered\n' >> "${tampered_release}/${BOOTSTRAP_ASSET}"
tampered_home="${TMP_HOME}/bootstrap-tampered-home"
mkdir -p "${tampered_home}/.vibeguard/dist/old"
ln -s old "${tampered_home}/.vibeguard/dist/current"
tampered_rc=0
tampered_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${tampered_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${tampered_release}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --dry-run --yes 2>&1
)" || tampered_rc=$?
assert_cmd "tampered payload fails checksum verification" test "${tampered_rc}" -ne 0
assert_contains "${tampered_out}" "payload checksum verification failed" "tampered payload names checksum failure"
assert_cmd "tampered payload preserves the previous current target" bash -c \
  'test "$(readlink "$1")" = old && test ! -e "$2"' _ \
  "${tampered_home}/.vibeguard/dist/current" \
  "${tampered_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}"

bad_sums_home="${TMP_HOME}/bootstrap-bad-sums-home"
mkdir -p "${bad_sums_home}"
bad_sums_rc=0
bad_sums_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${bad_sums_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${BOOTSTRAP_RELEASE}" \
    VIBEGUARD_TEST_BAD_SHA=1 \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --dry-run --yes 2>&1
)" || bad_sums_rc=$?
assert_cmd "tampered checksum manifest fails verification" test "${bad_sums_rc}" -ne 0
assert_contains "${bad_sums_out}" "payload checksum verification failed" "tampered checksum is fail-visible"
assert_cmd "tampered checksum creates no version or current" bash -c \
  'test ! -e "$1" && test ! -L "$1" && test ! -e "$2"' _ \
  "${bad_sums_home}/.vibeguard/dist/current" \
  "${bad_sums_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}"

make_hostile_bootstrap_release() {
  local release_dir="$1" kind="$2"
  mkdir -p "${release_dir}"
  python3 - "${release_dir}/${BOOTSTRAP_ASSET}" "${BOOTSTRAP_VERSION}" "${kind}" <<'PY'
import hashlib
import io
import sys
import tarfile

archive, version, kind = sys.argv[1:4]
manifest = b"scripts/setup/bootstrap.sh\n"
marker_version = "9.9.9" if kind == "version-mismatch" else version
marker = (
    f"version={marker_version}\n"
    f"manifest_sha256={hashlib.sha256(manifest).hexdigest()}\n"
    f"git_commit={'a' * 40}\n"
).encode()
if kind == "interrupt":
    setup = b"#!/usr/bin/env bash\nkill -TERM $$\n"
elif kind == "handoff":
    setup = b"#!/usr/bin/env bash\nprintf 'EXPECTED_FINAL_SETUP path=%s\\n' \"$0\"\n"
elif kind == "fail-once":
    setup = b"""#!/usr/bin/env bash
set -euo pipefail
marker="${VIBEGUARD_TEST_SETUP_FAIL_MARKER:?}"
if [[ ! -e "${marker}" ]]; then
  : > "${marker}"
  exit 42
fi
printf 'RETRY_SETUP_SUCCEEDED\\n'
"""
elif kind == "fail":
    setup = b"#!/usr/bin/env bash\nexit 42\n"
elif kind == "argv":
    setup = b"""#!/usr/bin/env bash
index=0
for arg in "$@"; do
  printf 'ARGV[%d]=%s\\n' "${index}" "${arg}"
  index=$((index + 1))
done
"""
elif kind == "wait":
    setup = b"""#!/usr/bin/env bash
set -euo pipefail
ready="${VIBEGUARD_TEST_SETUP_READY:?}"
continue_fifo="${VIBEGUARD_TEST_SETUP_CONTINUE_FIFO:?}"
: > "${ready}"
IFS= read -r signal < "${continue_fifo}"
[[ "${signal}" == "continue" ]]
printf 'WAIT_SETUP_SUCCEEDED\\n'
"""
elif kind == "foreign-owner":
    setup = b"""#!/usr/bin/env bash
set -euo pipefail
lock_dir="${VIBEGUARD_TEST_LOCK_DIR:?}"
printf 'pid=%s\\nnonce=foreign-owner\\n' "$$" > "${lock_dir}/owner"
exit 42
"""
else:
    setup = b"#!/usr/bin/env bash\nexit 0\n"
entries = {
    ".vibeguard-payload": (marker, 0o644),
    "scripts/release/payload-manifest.txt": (manifest, 0o644),
    "vibeguard-runtime/VERSION": ((version + "\n").encode(), 0o644),
    "setup.sh": (setup, 0o755),
}
with tarfile.open(archive, "w:gz") as payload:
    for name, (content, mode) in entries.items():
        info = tarfile.TarInfo(name)
        info.size = len(content)
        info.mode = mode
        payload.addfile(info, io.BytesIO(content))
    if kind == "traversal":
        content = b"escape\n"
        info = tarfile.TarInfo("../bootstrap-escaped")
        info.size = len(content)
        info.mode = 0o644
        payload.addfile(info, io.BytesIO(content))
    elif kind == "symlink":
        info = tarfile.TarInfo("unsafe-link")
        info.type = tarfile.SYMTYPE
        info.linkname = "../outside"
        info.mode = 0o777
        payload.addfile(info)
PY
  hostile_sha="$(shasum -a 256 "${release_dir}/${BOOTSTRAP_ASSET}" | awk '{print $1}')"
  printf '%s  %s\n' "${hostile_sha}" "${BOOTSTRAP_ASSET}" \
    > "${release_dir}/SHA256SUMS"
}

for hostile_kind in traversal symlink; do
  hostile_release="${TMP_HOME}/bootstrap-release-${hostile_kind}"
  hostile_home="${TMP_HOME}/bootstrap-${hostile_kind}-home"
  make_hostile_bootstrap_release "${hostile_release}" "${hostile_kind}"
  mkdir -p "${hostile_home}"
  hostile_rc=0
  hostile_out="$(
    env "${bootstrap_base_env[@]}" \
      HOME="${hostile_home}" \
      VIBEGUARD_TEST_RELEASE_DIR="${hostile_release}" \
      bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --dry-run --yes 2>&1
  )" || hostile_rc=$?
  assert_cmd "${hostile_kind} archive fails before extraction" test "${hostile_rc}" -ne 0
  assert_contains "${hostile_out}" "payload archive" "${hostile_kind} archive failure identifies archive safety"
  assert_cmd "${hostile_kind} archive creates no version or current" bash -c \
    'test ! -e "$1" && test ! -L "$1" && test ! -e "$2"' _ \
    "${hostile_home}/.vibeguard/dist/current" \
    "${hostile_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}"
done
assert_cmd "path traversal archive writes nothing outside staging" \
  test ! -e "${TMP_HOME}/bootstrap-escaped"

version_mismatch_release="${TMP_HOME}/bootstrap-release-version-mismatch"
version_mismatch_home="${TMP_HOME}/bootstrap-version-mismatch-home"
make_hostile_bootstrap_release "${version_mismatch_release}" "version-mismatch"
mkdir -p "${version_mismatch_home}"
version_mismatch_rc=0
version_mismatch_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${version_mismatch_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${version_mismatch_release}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --dry-run --yes 2>&1
)" || version_mismatch_rc=$?
assert_cmd "payload marker version mismatch fails closed" test "${version_mismatch_rc}" -ne 0
assert_contains "${version_mismatch_out}" "version metadata does not match" "version mismatch names the pin failure"
assert_cmd "version mismatch creates no version or current" bash -c \
  'test ! -e "$1" && test ! -L "$1" && test ! -e "$2"' _ \
  "${version_mismatch_home}/.vibeguard/dist/current" \
  "${version_mismatch_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}"

handoff_release="${TMP_HOME}/bootstrap-release-handoff"
handoff_home="${TMP_HOME}/bootstrap-handoff-home"
make_hostile_bootstrap_release "${handoff_release}" "handoff"
mkdir -p "${handoff_home}"
handoff_rc=0
handoff_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${handoff_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${handoff_release}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes 2>&1
)" || handoff_rc=$?
assert_cmd "bootstrap handoff executes the verified immutable version" test "${handoff_rc}" -eq 0
assert_contains "${handoff_out}" "EXPECTED_FINAL_SETUP" "handoff runs this bootstrap's verified setup"
assert_contains "${handoff_out}" \
  "path=${handoff_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}/setup.sh" \
  "handoff invokes setup from the exact verified immutable directory"

switch_failure_home="${TMP_HOME}/bootstrap-switch-failure-home"
switch_failure_bin="${TMP_HOME}/bootstrap-switch-failure-bin"
switch_failure_real_mv="$(command -v mv)"
mkdir -p "${switch_failure_home}/.vibeguard/dist/old" "${switch_failure_bin}"
ln -s old "${switch_failure_home}/.vibeguard/dist/current"
cat > "${switch_failure_bin}/mv" <<SH
#!/usr/bin/env bash
last_arg=""
for arg in "\$@"; do
  last_arg="\${arg}"
done
if [[ "\${last_arg}" == "${switch_failure_home}/.vibeguard/dist/current" ]]; then
  printf 'fake current switch failure\n' >&2
  exit 1
fi
exec "${switch_failure_real_mv}" "\$@"
SH
chmod +x "${switch_failure_bin}/mv"
switch_failure_rc=0
switch_failure_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${switch_failure_home}" \
    PATH="${switch_failure_bin}:${PATH}" \
    VIBEGUARD_TEST_RELEASE_DIR="${handoff_release}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes 2>&1
)" || switch_failure_rc=$?
assert_cmd "failed current helper exits nonzero" test "${switch_failure_rc}" -ne 0
assert_contains "${switch_failure_out}" "atomic" "failed current helper is visible"
assert_cmd "failed current helper removes only the newly owned final directory" bash -c \
  'test "$(readlink "$1")" = old && test -d "$2" && test ! -e "$3"' _ \
  "${switch_failure_home}/.vibeguard/dist/current" \
  "${switch_failure_home}/.vibeguard/dist/old" \
  "${switch_failure_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}"

switch_retry_rc=0
switch_retry_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${switch_failure_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${handoff_release}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes 2>&1
)" || switch_retry_rc=$?
assert_cmd "retry after current helper failure succeeds" test "${switch_retry_rc}" -eq 0
assert_contains "${switch_retry_out}" "EXPECTED_FINAL_SETUP" "retry executes the verified payload"
assert_cmd "successful retry preserves old version and commits exact current" bash -c \
  'test -d "$1" && test -d "$2" && test "$(readlink "$3")" = "$4"' _ \
  "${switch_failure_home}/.vibeguard/dist/old" \
  "${switch_failure_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}" \
  "${switch_failure_home}/.vibeguard/dist/current" \
  "${BOOTSTRAP_VERSION}"

argv_release="${TMP_HOME}/bootstrap-release-argv"
make_hostile_bootstrap_release "${argv_release}" "argv"
for argv_case in default explicit-install doctor verify-install clean; do
  argv_home="${TMP_HOME}/bootstrap-argv-${argv_case}-home"
  mkdir -p "${argv_home}"
  case "${argv_case}" in
    default)
      argv_setup_args=(--dry-run --yes)
      ;;
    explicit-install)
      argv_setup_args=(install --dry-run --yes)
      ;;
    doctor)
      argv_setup_args=(doctor --json)
      ;;
    verify-install)
      argv_setup_args=(verify-install --json)
      ;;
    clean)
      argv_setup_args=(--clean --purge-data)
      ;;
  esac
  argv_rc=0
  argv_out="$(
    env "${bootstrap_base_env[@]}" \
      HOME="${argv_home}" \
      VIBEGUARD_TEST_RELEASE_DIR="${argv_release}" \
      VIBEGUARD_TEST_ATTESTATION_AVAILABLE=1 \
      VIBEGUARD_TEST_GH_AUTH_OK=1 \
      VIBEGUARD_TEST_ATTESTATION_OK=1 \
      bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" \
        --require-provenance -- "${argv_setup_args[@]}" 2>&1
  )" || argv_rc=$?
  assert_cmd "provenance argv case ${argv_case} executes setup" test "${argv_rc}" -eq 0
  case "${argv_case}" in
    default)
      assert_contains "${argv_out}" "ARGV[0]=--require-provenance" \
        "default install receives provenance as its first install option"
      assert_contains "${argv_out}" "ARGV[1]=--dry-run" \
        "default install preserves existing option order"
      ;;
    explicit-install)
      assert_contains "${argv_out}" "ARGV[0]=install" \
        "explicit install remains the dispatcher command"
      assert_contains "${argv_out}" "ARGV[1]=--require-provenance" \
        "explicit install receives provenance after its command"
      ;;
    doctor|verify-install|clean)
      assert_contains "${argv_out}" "ARGV[0]=${argv_setup_args[0]}" \
        "${argv_case} remains the dispatcher command"
      assert_not_contains "${argv_out}" "--require-provenance" \
        "${argv_case} does not receive an install-only provenance option"
      ;;
  esac
done

lock_wait_release="${TMP_HOME}/bootstrap-release-lock-wait"
lock_wait_home="${TMP_HOME}/bootstrap-lock-wait-home"
lock_wait_ready="${TMP_HOME}/bootstrap-lock-wait.ready"
lock_wait_fifo="${TMP_HOME}/bootstrap-lock-wait.fifo"
lock_wait_first_out="${TMP_HOME}/bootstrap-lock-wait-first.out"
lock_wait_first_download="${TMP_HOME}/bootstrap-lock-wait-first-download.log"
lock_wait_second_download="${TMP_HOME}/bootstrap-lock-wait-second-download.log"
make_hostile_bootstrap_release "${lock_wait_release}" "wait"
mkdir -p "${lock_wait_home}"
mkfifo "${lock_wait_fifo}"
: > "${lock_wait_first_download}"
: > "${lock_wait_second_download}"
env "${bootstrap_base_env[@]}" \
  HOME="${lock_wait_home}" \
  VIBEGUARD_TEST_RELEASE_DIR="${lock_wait_release}" \
  VIBEGUARD_TEST_DOWNLOAD_LOG="${lock_wait_first_download}" \
  VIBEGUARD_TEST_SETUP_READY="${lock_wait_ready}" \
  VIBEGUARD_TEST_SETUP_CONTINUE_FIFO="${lock_wait_fifo}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes \
  >"${lock_wait_first_out}" 2>&1 &
lock_wait_first_pid=$!
for _lock_wait_attempt in {1..100}; do
  [[ -e "${lock_wait_ready}" ]] && break
  sleep 0.05
done
assert_cmd "first bootstrap reaches setup handshake while owning the lock" \
  test -e "${lock_wait_ready}"
lock_wait_second_rc=0
lock_wait_second_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${lock_wait_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${lock_wait_release}" \
    VIBEGUARD_TEST_DOWNLOAD_LOG="${lock_wait_second_download}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes 2>&1
)" || lock_wait_second_rc=$?
assert_cmd "concurrent bootstrap is rejected while first setup is running" \
  test "${lock_wait_second_rc}" -eq 73
assert_contains "${lock_wait_second_out}" "active bootstrap owner pid=" \
  "concurrent rejection identifies active bootstrap ownership"
assert_cmd "rejected concurrent bootstrap performs no download" \
  test ! -s "${lock_wait_second_download}"
printf 'continue\n' > "${lock_wait_fifo}"
lock_wait_first_rc=0
wait "${lock_wait_first_pid}" || lock_wait_first_rc=$?
assert_cmd "first bootstrap completes after deterministic setup handshake" \
  test "${lock_wait_first_rc}" -eq 0
assert_cmd "first bootstrap releases lock only after setup completes" \
  test ! -e "${lock_wait_home}/.vibeguard/dist/.bootstrap.lock"
assert_contains "$(cat "${lock_wait_first_out}")" "WAIT_SETUP_SUCCEEDED" \
  "first setup consumed the continuation handshake"

dangling_failure_home="${TMP_HOME}/bootstrap-dangling-switch-failure-home"
dangling_failure_bin="${TMP_HOME}/bootstrap-dangling-switch-failure-bin"
mkdir -p "${dangling_failure_home}/.vibeguard/dist" "${dangling_failure_bin}"
ln -s "${BOOTSTRAP_VERSION}" "${dangling_failure_home}/.vibeguard/dist/current"
cat > "${dangling_failure_bin}/mv" <<SH
#!/usr/bin/env bash
last_arg=""
for arg in "\$@"; do
  last_arg="\${arg}"
done
if [[ "\${last_arg}" == "${dangling_failure_home}/.vibeguard/dist/current" ]]; then
  printf 'fake dangling current switch failure\n' >&2
  exit 1
fi
exec "${switch_failure_real_mv}" "\$@"
SH
chmod +x "${dangling_failure_bin}/mv"
dangling_failure_rc=0
dangling_failure_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${dangling_failure_home}" \
    PATH="${dangling_failure_bin}:${PATH}" \
    VIBEGUARD_TEST_RELEASE_DIR="${handoff_release}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes 2>&1
)" || dangling_failure_rc=$?
assert_cmd "failed switch from same-version dangling current exits nonzero" \
  test "${dangling_failure_rc}" -ne 0
assert_contains "${dangling_failure_out}" "atomic" \
  "same-version dangling current switch failure is visible"
assert_cmd "failed switch restores same-version current to a dangling link" bash -c \
  'test -L "$1" && test ! -e "$1" && test "$(readlink "$1")" = "$2" && test ! -e "$3"' _ \
  "${dangling_failure_home}/.vibeguard/dist/current" \
  "${BOOTSTRAP_VERSION}" \
  "${dangling_failure_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}"

dangling_retry_rc=0
dangling_retry_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${dangling_failure_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${handoff_release}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes 2>&1
)" || dangling_retry_rc=$?
assert_cmd "retry after same-version dangling current failure succeeds" \
  test "${dangling_retry_rc}" -eq 0
assert_contains "${dangling_retry_out}" "EXPECTED_FINAL_SETUP" \
  "dangling-current retry executes the verified payload"
assert_cmd "dangling-current retry commits the exact verified version" bash -c \
  'test -d "$1" && test -L "$2" && test "$(readlink "$2")" = "$3"' _ \
  "${dangling_failure_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}" \
  "${dangling_failure_home}/.vibeguard/dist/current" \
  "${BOOTSTRAP_VERSION}"

setup_retry_release="${TMP_HOME}/bootstrap-release-setup-retry"
setup_retry_home="${TMP_HOME}/bootstrap-setup-retry-home"
setup_retry_marker="${TMP_HOME}/bootstrap-setup-retry.marker"
setup_retry_download_log="${TMP_HOME}/bootstrap-setup-retry-download.log"
make_hostile_bootstrap_release "${setup_retry_release}" "fail-once"
mkdir -p "${setup_retry_home}/.vibeguard/dist/old"
ln -s old "${setup_retry_home}/.vibeguard/dist/current"
: > "${setup_retry_download_log}"
setup_failure_rc=0
setup_failure_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${setup_retry_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${setup_retry_release}" \
    VIBEGUARD_TEST_DOWNLOAD_LOG="${setup_retry_download_log}" \
    VIBEGUARD_TEST_SETUP_FAIL_MARKER="${setup_retry_marker}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes 2>&1
)" || setup_failure_rc=$?
assert_cmd "failed payload setup preserves its exact exit status" \
  test "${setup_failure_rc}" -eq 42
assert_contains "${setup_failure_out}" "rolling back bootstrap transaction" \
  "failed payload setup reports transactional rollback"
assert_cmd "failed payload setup restores the exact previous current symlink" bash -c \
  'test -L "$1" && test "$(readlink "$1")" = old && test -d "$2"' _ \
  "${setup_retry_home}/.vibeguard/dist/current" \
  "${setup_retry_home}/.vibeguard/dist/old"
assert_cmd "failed payload setup removes only this attempt's final directory" \
  test ! -e "${setup_retry_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}"
assert_cmd "failed payload setup releases its bootstrap lock" \
  test ! -e "${setup_retry_home}/.vibeguard/dist/.bootstrap.lock"

setup_retry_rc=0
setup_retry_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${setup_retry_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${setup_retry_release}" \
    VIBEGUARD_TEST_DOWNLOAD_LOG="${setup_retry_download_log}" \
    VIBEGUARD_TEST_SETUP_FAIL_MARKER="${setup_retry_marker}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes 2>&1
)" || setup_retry_rc=$?
assert_cmd "same exact version retries completely after setup failure" \
  test "${setup_retry_rc}" -eq 0
assert_contains "${setup_retry_out}" "RETRY_SETUP_SUCCEEDED" \
  "same-version retry executes a freshly staged payload"
assert_cmd "same-version retry downloads and verifies the payload again" bash -c \
  'test "$(grep -c "^gh tag=" "$1")" -eq 2' _ "${setup_retry_download_log}"
assert_cmd "same-version retry preserves old version and commits exact current" bash -c \
  'test -d "$1" && test -d "$2" && test "$(readlink "$3")" = "$4"' _ \
  "${setup_retry_home}/.vibeguard/dist/old" \
  "${setup_retry_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}" \
  "${setup_retry_home}/.vibeguard/dist/current" \
  "${BOOTSTRAP_VERSION}"

setup_no_current_release="${TMP_HOME}/bootstrap-release-setup-no-current"
setup_no_current_home="${TMP_HOME}/bootstrap-setup-no-current-home"
make_hostile_bootstrap_release "${setup_no_current_release}" "fail"
mkdir -p "${setup_no_current_home}"
setup_no_current_rc=0
env "${bootstrap_base_env[@]}" \
  HOME="${setup_no_current_home}" \
  VIBEGUARD_TEST_RELEASE_DIR="${setup_no_current_release}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes \
  >/dev/null 2>&1 || setup_no_current_rc=$?
assert_cmd "failed payload setup without previous current preserves child failure" \
  test "${setup_no_current_rc}" -eq 42
assert_cmd "failed payload setup restores an exact no-current state" bash -c \
  'test ! -e "$1" && test ! -L "$1" && test ! -e "$2"' _ \
  "${setup_no_current_home}/.vibeguard/dist/current" \
  "${setup_no_current_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}"

rollback_failure_home="${TMP_HOME}/bootstrap-rollback-failure-home"
rollback_failure_bin="${TMP_HOME}/bootstrap-rollback-failure-bin"
rollback_failure_count="${TMP_HOME}/bootstrap-rollback-failure.count"
mkdir -p "${rollback_failure_home}/.vibeguard/dist/old" "${rollback_failure_bin}"
ln -s old "${rollback_failure_home}/.vibeguard/dist/current"
printf '0\n' > "${rollback_failure_count}"
cat > "${rollback_failure_bin}/mv" <<SH
#!/usr/bin/env bash
last_arg=""
for arg in "\$@"; do
  last_arg="\${arg}"
done
if [[ "\${last_arg}" == "${rollback_failure_home}/.vibeguard/dist/current" ]]; then
  count="\$(cat "${rollback_failure_count}")"
  count="\$((count + 1))"
  printf '%s\n' "\${count}" > "${rollback_failure_count}"
  if [[ "\${count}" -gt 1 ]]; then
    printf 'fake rollback failure\n' >&2
    exit 1
  fi
fi
exec "${switch_failure_real_mv}" "\$@"
SH
chmod +x "${rollback_failure_bin}/mv"
rollback_failure_rc=0
rollback_failure_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${rollback_failure_home}" \
    PATH="${rollback_failure_bin}:${PATH}" \
    VIBEGUARD_TEST_RELEASE_DIR="${setup_no_current_release}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes 2>&1
)" || rollback_failure_rc=$?
assert_cmd "failed rollback exits nonzero" test "${rollback_failure_rc}" -ne 0
assert_contains "${rollback_failure_out}" "rollback" \
  "failed rollback is explicit"
assert_cmd "failed rollback preserves current-referenced payload evidence" bash -c \
  'test -L "$1" && test "$(readlink "$1")" = "$2" && test -d "$3" && test -d "$4"' _ \
  "${rollback_failure_home}/.vibeguard/dist/current" \
  "${BOOTSTRAP_VERSION}" \
  "${rollback_failure_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}" \
  "${rollback_failure_home}/.vibeguard/dist/old"

current_file_home="${TMP_HOME}/bootstrap-current-file-home"
mkdir -p "${current_file_home}/.vibeguard/dist"
printf 'unmanaged\n' > "${current_file_home}/.vibeguard/dist/current"
current_file_rc=0
current_file_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${current_file_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${BOOTSTRAP_RELEASE}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --dry-run --yes 2>&1
)" || current_file_rc=$?
assert_cmd "bootstrap refuses a non-symlink current path" test "${current_file_rc}" -ne 0
assert_contains "${current_file_out}" "current exists and is not a symlink" "current conflict is actionable"
assert_cmd "bootstrap preserves an unmanaged current file" \
  grep -qFx "unmanaged" "${current_file_home}/.vibeguard/dist/current"

active_lock_home="${TMP_HOME}/bootstrap-active-lock-home"
active_lock_dir="${active_lock_home}/.vibeguard/dist/.bootstrap.lock"
mkdir -p "${active_lock_dir}"
printf 'pid=%s\nnonce=active-owner\n' "$$" > "${active_lock_dir}/owner"
active_lock_rc=0
active_lock_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${active_lock_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${BOOTSTRAP_RELEASE}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --dry-run --yes 2>&1
)" || active_lock_rc=$?
assert_cmd "bootstrap rejects an active lock owner" test "${active_lock_rc}" -eq 73
assert_contains "${active_lock_out}" "active bootstrap owner pid=$$" \
  "active lock rejection identifies its owner pid"
assert_cmd "active lock rejection preserves exact foreign owner metadata" \
  grep -qFx "nonce=active-owner" "${active_lock_dir}/owner"
assert_cmd "active lock conflict performs no download or install" \
  test ! -e "${active_lock_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}"

dead_lock_home="${TMP_HOME}/bootstrap-dead-lock-home"
dead_lock_dir="${dead_lock_home}/.vibeguard/dist/.bootstrap.lock"
mkdir -p "${dead_lock_dir}"
(exit 0) &
dead_lock_pid=$!
wait "${dead_lock_pid}"
printf 'pid=%s\nnonce=dead-owner\n' "${dead_lock_pid}" > "${dead_lock_dir}/owner"
dead_lock_rc=0
dead_lock_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${dead_lock_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${handoff_release}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes 2>&1
)" || dead_lock_rc=$?
assert_cmd "bootstrap reaps a dead lock owner and retries acquisition" \
  test "${dead_lock_rc}" -eq 0
assert_contains "${dead_lock_out}" "EXPECTED_FINAL_SETUP" \
  "dead-owner recovery continues through verified setup"
assert_cmd "dead-owner recovery leaves no lock or reap directory" bash -c \
  'test ! -e "$1" && test -z "$(find "$2" -maxdepth 1 -name ".bootstrap.lock.reap.*" -print -quit)"' _ \
  "${dead_lock_dir}" "${dead_lock_home}/.vibeguard/dist"

stale_race_home="${TMP_HOME}/bootstrap-stale-race-home"
stale_race_dir="${stale_race_home}/.vibeguard/dist/.bootstrap.lock"
stale_race_bin="${TMP_HOME}/bootstrap-stale-race-bin"
stale_race_real_mv="$(command -v mv)"
mkdir -p "${stale_race_dir}" "${stale_race_bin}"
printf 'pid=%s\nnonce=dead-race-owner\n' "${dead_lock_pid}" > "${stale_race_dir}/owner"
cat > "${stale_race_bin}/mv" <<SH
#!/usr/bin/env bash
previous=""
last=""
for arg in "\$@"; do
  previous="\${last}"
  last="\${arg}"
done
if [[ "\${previous}" == "${stale_race_dir}" ]]; then
  printf 'pid=%s\\nnonce=racing-active-owner\\n' "$$" > "${stale_race_dir}/owner"
fi
exec "${stale_race_real_mv}" "\$@"
SH
chmod +x "${stale_race_bin}/mv"
stale_race_rc=0
stale_race_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${stale_race_home}" \
    PATH="${stale_race_bin}:${PATH}" \
    VIBEGUARD_TEST_RELEASE_DIR="${BOOTSTRAP_RELEASE}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --dry-run --yes 2>&1
)" || stale_race_rc=$?
assert_cmd "stale-owner recovery fails closed when ownership races before rename" \
  test "${stale_race_rc}" -eq 73
assert_contains "${stale_race_out}" "lock ownership changed" \
  "stale-owner race is detected after the directory rename"
assert_cmd "stale-owner race preserves the replacement active owner" bash -c \
  'test -d "$1" && grep -qFx "nonce=racing-active-owner" "$1/owner"' _ \
  "${stale_race_dir}"
assert_cmd "stale-owner race performs no download or install" \
  test ! -e "${stale_race_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}"

missing_owner_home="${TMP_HOME}/bootstrap-missing-owner-home"
missing_owner_dir="${missing_owner_home}/.vibeguard/dist/.bootstrap.lock"
mkdir -p "${missing_owner_dir}"
missing_owner_rc=0
missing_owner_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${missing_owner_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${BOOTSTRAP_RELEASE}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --dry-run --yes 2>&1
)" || missing_owner_rc=$?
assert_cmd "bootstrap fails closed on missing lock owner metadata" \
  test "${missing_owner_rc}" -eq 73
assert_contains "${missing_owner_out}" "lock owner metadata is missing" \
  "missing lock owner failure is explicit"
assert_cmd "missing owner lock is never reaped" test -d "${missing_owner_dir}"

malformed_owner_home="${TMP_HOME}/bootstrap-malformed-owner-home"
malformed_owner_dir="${malformed_owner_home}/.vibeguard/dist/.bootstrap.lock"
mkdir -p "${malformed_owner_dir}"
printf 'pid=not-a-pid\nnonce=\n' > "${malformed_owner_dir}/owner"
malformed_owner_rc=0
malformed_owner_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${malformed_owner_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${BOOTSTRAP_RELEASE}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --dry-run --yes 2>&1
)" || malformed_owner_rc=$?
assert_cmd "bootstrap fails closed on malformed lock owner metadata" \
  test "${malformed_owner_rc}" -eq 73
assert_contains "${malformed_owner_out}" "lock owner metadata is malformed" \
  "malformed lock owner failure is explicit"
assert_cmd "malformed owner lock is never reaped" \
  grep -qFx "pid=not-a-pid" "${malformed_owner_dir}/owner"

symlink_owner_home="${TMP_HOME}/bootstrap-symlink-owner-home"
symlink_owner_dir="${symlink_owner_home}/.vibeguard/dist/.bootstrap.lock"
symlink_owner_foreign="${TMP_HOME}/bootstrap-symlink-owner.foreign"
mkdir -p "${symlink_owner_dir}"
printf 'pid=%s\nnonce=symlink-foreign\n' "$$" > "${symlink_owner_foreign}"
ln -s "${symlink_owner_foreign}" "${symlink_owner_dir}/owner"
symlink_owner_rc=0
symlink_owner_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${symlink_owner_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${BOOTSTRAP_RELEASE}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --dry-run --yes 2>&1
)" || symlink_owner_rc=$?
assert_cmd "bootstrap fails closed on symlink lock owner metadata" \
  test "${symlink_owner_rc}" -eq 73
assert_contains "${symlink_owner_out}" "lock owner metadata must be a regular file" \
  "symlink owner failure is explicit"
assert_cmd "symlink owner failure preserves foreign target" \
  grep -qFx "nonce=symlink-foreign" "${symlink_owner_foreign}"

foreign_owner_release="${TMP_HOME}/bootstrap-release-foreign-owner"
foreign_owner_home="${TMP_HOME}/bootstrap-foreign-owner-home"
foreign_owner_lock="${foreign_owner_home}/.vibeguard/dist/.bootstrap.lock"
make_hostile_bootstrap_release "${foreign_owner_release}" "foreign-owner"
mkdir -p "${foreign_owner_home}"
foreign_owner_rc=0
foreign_owner_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${foreign_owner_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${foreign_owner_release}" \
    VIBEGUARD_TEST_LOCK_DIR="${foreign_owner_lock}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes 2>&1
)" || foreign_owner_rc=$?
assert_cmd "foreign lock owner replacement fails bootstrap visibly" \
  test "${foreign_owner_rc}" -ne 0
assert_contains "${foreign_owner_out}" "lock ownership changed" \
  "cleanup reports foreign lock ownership instead of deleting it"
assert_cmd "cleanup never deletes a foreign lock owner" \
  grep -qFx "nonce=foreign-owner" "${foreign_owner_lock}/owner"

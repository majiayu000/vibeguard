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
    setup = b"#!/usr/bin/env bash\nprintf 'EXPECTED_FINAL_SETUP\\n'\n"
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
handoff_bin="${TMP_HOME}/bootstrap-handoff-bin"
handoff_real_rmdir="$(command -v rmdir)"
make_hostile_bootstrap_release "${handoff_release}" "handoff"
mkdir -p "${handoff_home}/.vibeguard/dist/other" "${handoff_bin}"
cat > "${handoff_home}/.vibeguard/dist/other/setup.sh" <<'SH'
#!/usr/bin/env bash
printf 'WRONG_CURRENT_SETUP\n'
SH
chmod +x "${handoff_home}/.vibeguard/dist/other/setup.sh"
cat > "${handoff_bin}/rmdir" <<SH
#!/usr/bin/env bash
if [[ "\${1:-}" == "${handoff_home}/.vibeguard/dist/.bootstrap.lock" ]]; then
  rm -f -- "${handoff_home}/.vibeguard/dist/current"
  ln -s other "${handoff_home}/.vibeguard/dist/current"
fi
exec "${handoff_real_rmdir}" "\$@"
SH
chmod +x "${handoff_bin}/rmdir"
handoff_rc=0
handoff_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${handoff_home}" \
    PATH="${handoff_bin}:${PATH}" \
    VIBEGUARD_TEST_RELEASE_DIR="${handoff_release}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes 2>&1
)" || handoff_rc=$?
assert_cmd "bootstrap handoff executes the verified immutable version" test "${handoff_rc}" -eq 0
assert_contains "${handoff_out}" "EXPECTED_FINAL_SETUP" "handoff runs this bootstrap's verified setup"
assert_not_contains "${handoff_out}" "WRONG_CURRENT_SETUP" "handoff ignores a later current-link change"
assert_cmd "handoff fixture changes current only after lock release" bash -c \
  'test -L "$1" && test "$(readlink "$1")" = other' _ \
  "${handoff_home}/.vibeguard/dist/current"

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

interrupt_release="${TMP_HOME}/bootstrap-release-interrupt"
interrupt_home="${TMP_HOME}/bootstrap-interrupt-home"
make_hostile_bootstrap_release "${interrupt_release}" "interrupt"
mkdir -p "${interrupt_home}"
interrupt_rc=0
env "${bootstrap_base_env[@]}" \
  HOME="${interrupt_home}" \
  VIBEGUARD_TEST_RELEASE_DIR="${interrupt_release}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes \
  >/dev/null 2>&1 || interrupt_rc=$?
assert_cmd "interrupted payload setup exits nonzero" test "${interrupt_rc}" -ne 0
assert_cmd "interrupted setup cannot publish an active installed snapshot" \
  test ! -e "${interrupt_home}/.vibeguard/installed"
assert_cmd "interrupted setup leaves only the verified immutable dist selected" bash -c \
  'test -d "$1" && test -L "$2" && test "$(readlink "$2")" = "$3"' _ \
  "${interrupt_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}" \
  "${interrupt_home}/.vibeguard/dist/current" \
  "${BOOTSTRAP_VERSION}"

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

locked_home="${TMP_HOME}/bootstrap-locked-home"
mkdir -p "${locked_home}/.vibeguard/dist/.bootstrap.lock"
locked_rc=0
locked_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${locked_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${BOOTSTRAP_RELEASE}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --dry-run --yes 2>&1
)" || locked_rc=$?
assert_cmd "bootstrap fails visible on concurrent lock ownership" test "${locked_rc}" -eq 73
assert_contains "${locked_out}" "another bootstrap owns" "concurrent bootstrap names lock ownership"
assert_cmd "lock conflict performs no download or install" \
  test ! -e "${locked_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}"

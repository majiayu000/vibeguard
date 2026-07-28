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
  'test "$(wc -l < "$1")" -lt 600' _ "${BOOTSTRAP}"
assert_cmd "bootstrap helper stays below focused limit" bash -c \
  'test "$(wc -l < "$1")" -lt 600' _ "${BOOTSTRAP_LIB}"

busybox_mv_bin="${TMP_HOME}/bootstrap-busybox-mv-bin"
busybox_mv_marker="${TMP_HOME}/bootstrap-busybox-mv.marker"
busybox_mv_root="${TMP_HOME}/bootstrap-busybox-mv-root"
mkdir -p "${busybox_mv_bin}" "${busybox_mv_root}/old" "${busybox_mv_root}/new"
ln -s old "${busybox_mv_root}/current"
ln -s new "${busybox_mv_root}/next"
cat > "${busybox_mv_bin}/mv" <<SH
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then exit 1; fi
if [[ "\${1:-}" == "-fT" && "\${2:-}" == "--" ]]; then
  printf 'busybox-t\\n' > "${busybox_mv_marker}"
  exec python3 -c 'import os,sys; os.replace(sys.argv[1], sys.argv[2])' "\${3}" "\${4}"
fi
exit 64
SH
chmod +x "${busybox_mv_bin}/mv"
assert_cmd "atomic current switch probes BusyBox-compatible mv -T capability" bash -c '
  set -euo pipefail
  PATH="$1:$PATH"
  source "$2"
  bootstrap_atomic_replace_symlink "$3" "$4"
  test "$(readlink "$4")" = new
' _ "${busybox_mv_bin}" "${BOOTSTRAP_LIB}" \
  "${busybox_mv_root}/next" "${busybox_mv_root}/current"
assert_cmd "BusyBox mv capability path was exercised without a GNU version banner" \
  grep -qFx "busybox-t" "${busybox_mv_marker}"

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
assert_cmd "bootstrap safely revalidates an existing transactional dist version" test "${repeat_rc}" -eq 0
assert_contains "${repeat_out}" "Resuming verified bootstrap transaction" \
  "same-version revalidation reports its repair transaction"
assert_cmd "version conflict preserves the selected current target" bash -c \
  'test "$(readlink "$1")" = "$2"' _ \
  "${verified_home}/.vibeguard/dist/current" "${BOOTSTRAP_VERSION}"

payload_ancestor="${TMP_HOME}/bootstrap-payload-ancestor"
payload_ancestor_home="${payload_ancestor}/user-home"
payload_ancestor_root="${payload_ancestor}/payload"
payload_ancestor_pre_commit_target="${payload_ancestor}/preserve-pre-commit"
payload_ancestor_pre_push_target="${payload_ancestor}/preserve-pre-push"
mkdir -p "${payload_ancestor_home}" "${payload_ancestor_root}"
git init -q "${payload_ancestor}"
tar -xzf "${BOOTSTRAP_RELEASE}/${BOOTSTRAP_ASSET}" -C "${payload_ancestor_root}"
cp "${REPO_DIR}/scripts/setup/install.sh" \
  "${payload_ancestor_root}/scripts/setup/install.sh"
cp "${REPO_DIR}/scripts/setup/check.sh" \
  "${payload_ancestor_root}/scripts/setup/check.sh"
printf 'preserve pre-commit\n' > "${payload_ancestor_pre_commit_target}"
printf 'preserve pre-push\n' > "${payload_ancestor_pre_push_target}"
ln -s "${payload_ancestor_pre_commit_target}" \
  "${payload_ancestor}/.git/hooks/pre-commit"
ln -s "${payload_ancestor_pre_push_target}" \
  "${payload_ancestor}/.git/hooks/pre-push"
payload_ancestor_rc=0
payload_ancestor_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${payload_ancestor_home}" \
    VIBEGUARD_TEST_UNAME=Linux \
    VIBEGUARD_TEST_RELEASE_DIR="${BOOTSTRAP_RELEASE}" \
    bash "${payload_ancestor_root}/setup.sh" --yes 2>&1
)" || payload_ancestor_rc=$?
assert_cmd "payload install inside an ancestor checkout succeeds without adopting it" \
  test "${payload_ancestor_rc}" -eq 0
assert_contains "${payload_ancestor_out}" "SKIP repo git hooks (payload mode)" \
  "payload install reports that repository hooks are not applicable"
assert_cmd "payload install preserves ancestor repository hooks byte-for-byte" bash -c \
  'test -L "$1" && test "$(readlink "$1")" = "$2" && test -L "$3" && test "$(readlink "$3")" = "$4"' _ \
  "${payload_ancestor}/.git/hooks/pre-commit" \
  "${payload_ancestor_pre_commit_target}" \
  "${payload_ancestor}/.git/hooks/pre-push" \
  "${payload_ancestor_pre_push_target}"
assert_cmd "payload install records no ancestor project-hook ownership" bash -c \
  '! grep -qF "$1" "$2"' _ "${payload_ancestor}/.git/hooks" \
  "${payload_ancestor_home}/.vibeguard/install-state.json"

unmanaged_version_home="${TMP_HOME}/bootstrap-unmanaged-version-home"
mkdir -p "${unmanaged_version_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}"
printf 'unmanaged\n' \
  > "${unmanaged_version_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}/sentinel"
unmanaged_version_rc=0
unmanaged_version_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${unmanaged_version_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${BOOTSTRAP_RELEASE}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --dry-run --yes 2>&1
)" || unmanaged_version_rc=$?
assert_cmd "bootstrap rejects an existing version without transaction evidence" \
  test "${unmanaged_version_rc}" -eq 73
assert_contains "${unmanaged_version_out}" "without repair evidence" \
  "unmanaged version conflict is explicit"
assert_cmd "unmanaged version conflict preserves exact existing contents" \
  grep -qFx "unmanaged" \
  "${unmanaged_version_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}/sentinel"

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
repo_dir="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "${HOME}/.vibeguard/installed"
printf '%s\\n' "${repo_dir}" > "${HOME}/.vibeguard/repo-path"
printf 'partial\\n' > "${HOME}/.vibeguard/installed/version"
printf '%s\\n' "${repo_dir}/scripts/gc/gc-scheduled.sh" > "${HOME}/.vibeguard/managed-reference"
if [[ ! -e "${marker}" ]]; then
  : > "${marker}"
  exit 42
fi
printf 'repaired\\n' > "${HOME}/.vibeguard/installed/version"
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
lock_file="${VIBEGUARD_TEST_LOCK_DIR:?}"
printf 'pid=%s\\nnonce=foreign-owner\\n' "$$" > "${lock_file}"
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
default_no_args_home="${TMP_HOME}/bootstrap-default-no-args-home"
mkdir -p "${default_no_args_home}"
default_no_args_rc=0
default_no_args_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${default_no_args_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${argv_release}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" 2>&1
)" || default_no_args_rc=$?
assert_cmd "bootstrap default install supports zero forwarded arguments" \
  test "${default_no_args_rc}" -eq 0
assert_not_contains "${default_no_args_out}" "ARGV[0]=" \
  "zero-argument setup handoff passes no synthetic argument"
provenance_no_args_home="${TMP_HOME}/bootstrap-provenance-no-args-home"
mkdir -p "${provenance_no_args_home}"
provenance_no_args_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${provenance_no_args_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${argv_release}" \
    VIBEGUARD_TEST_ATTESTATION_AVAILABLE=1 \
    VIBEGUARD_TEST_GH_AUTH_OK=1 \
    VIBEGUARD_TEST_ATTESTATION_OK=1 \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" \
      --require-provenance 2>&1
)"
assert_contains "${provenance_no_args_out}" "ARGV[0]=--require-provenance" \
  "zero-forwarded-argument provenance install avoids empty-array expansion"
for argv_case in \
  default \
  explicit-install \
  explicit-install-pack \
  explicit-install-pack-equals \
  doctor \
  verify-install \
  clean; do
  argv_home="${TMP_HOME}/bootstrap-argv-${argv_case}-home"
  mkdir -p "${argv_home}"
  case "${argv_case}" in
    default)
      argv_setup_args=(--dry-run --yes)
      ;;
    explicit-install)
      argv_setup_args=(install --dry-run --yes)
      ;;
    explicit-install-pack)
      argv_setup_args=(install --pack core --yes)
      ;;
    explicit-install-pack-equals)
      argv_setup_args=(install --yes --pack=core)
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
    explicit-install-pack)
      assert_contains "${argv_out}" "ARGV[0]=install" \
        "pack install remains the dispatcher command"
      assert_contains "${argv_out}" "ARGV[1]=--pack" \
        "pack install preserves its split pack option"
      assert_not_contains "${argv_out}" "--require-provenance" \
        "pack install does not receive install-parser provenance"
      ;;
    explicit-install-pack-equals)
      assert_contains "${argv_out}" "ARGV[2]=--pack=core" \
        "pack install preserves its equals-form pack option and order"
      assert_not_contains "${argv_out}" "--require-provenance" \
        "equals-form pack install does not receive install-parser provenance"
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
assert_cmd "same-version dangling current becomes valid without a needless switch" \
  test "${dangling_failure_rc}" -eq 0
assert_contains "${dangling_failure_out}" "EXPECTED_FINAL_SETUP" \
  "same-version dangling current executes the verified payload"
assert_cmd "same-version dangling current now selects the verified directory" bash -c \
  'test -L "$1" && test -e "$1" && test "$(readlink "$1")" = "$2" && test -d "$3"' _ \
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
assert_contains "${setup_failure_out}" "preserving verified payload for repair" \
  "failed payload setup reports recoverable transaction retention"
assert_cmd "failed setup keeps current on the referenced verified payload" bash -c \
  'test -L "$1" && test "$(readlink "$1")" = "$2" && test -d "$3" && test -d "$4"' _ \
  "${setup_retry_home}/.vibeguard/dist/current" \
  "${BOOTSTRAP_VERSION}" \
  "${setup_retry_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}" \
  "${setup_retry_home}/.vibeguard/dist/old"
assert_cmd "failed setup leaves no managed reference to a deleted payload" bash -c \
  'target="$(cat "$1")" && test "$target" = "$2" && test -d "$target" && grep -qFx "$2/scripts/gc/gc-scheduled.sh" "$3"' _ \
  "${setup_retry_home}/.vibeguard/repo-path" \
  "${setup_retry_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}" \
  "${setup_retry_home}/.vibeguard/managed-reference"
assert_cmd "failed setup persists a repairable setup transaction" bash -c \
  'test -f "$1" && grep -qFx "version=$2" "$1" && grep -qFx "phase=setup" "$1"' _ \
  "${setup_retry_home}/.vibeguard/dist/.bootstrap-transaction-${BOOTSTRAP_VERSION}" \
  "${BOOTSTRAP_VERSION}"
assert_cmd "failed payload setup releases its bootstrap lock" \
  test ! -e "${setup_retry_home}/.vibeguard/dist/.bootstrap.lock"

chmod +x "${setup_retry_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}/.vibeguard-payload"
mode_drift_rc=0
mode_drift_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${setup_retry_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${setup_retry_release}" \
    VIBEGUARD_TEST_DOWNLOAD_LOG="${setup_retry_download_log}" \
    VIBEGUARD_TEST_SETUP_FAIL_MARKER="${setup_retry_marker}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes 2>&1
)" || mode_drift_rc=$?
assert_cmd "same-version retry rejects retained payload permission drift" \
  test "${mode_drift_rc}" -eq 73
assert_contains "${mode_drift_out}" \
  "permissions or entry types differ from the verified payload" \
  "retained payload permission drift fails before setup"
chmod -x "${setup_retry_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}/.vibeguard-payload"

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
  'test "$(grep -c "^gh tag=" "$1")" -eq 3' _ "${setup_retry_download_log}"
assert_cmd "same-version retry repairs partial managed setup state" \
  grep -qFx "repaired" "${setup_retry_home}/.vibeguard/installed/version"
assert_cmd "same-version retry commits persistent transaction evidence" bash -c \
  'grep -qFx "phase=committed" "$1" && grep -qE "^payload_sha256=[0-9a-f]{64}$" "$1"' _ \
  "${setup_retry_home}/.vibeguard/dist/.bootstrap-transaction-${BOOTSTRAP_VERSION}"
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
assert_cmd "failed payload setup without previous current retains a repair path" bash -c \
  'test -L "$1" && test "$(readlink "$1")" = "$3" && test -d "$2" && grep -qFx "phase=setup" "$4"' _ \
  "${setup_no_current_home}/.vibeguard/dist/current" \
  "${setup_no_current_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}" \
  "${BOOTSTRAP_VERSION}" \
  "${setup_no_current_home}/.vibeguard/dist/.bootstrap-transaction-${BOOTSTRAP_VERSION}"

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
assert_cmd "portable PID classifier treats real PID 1 as active" bash -c '
  source "$1"
  bootstrap_pid_liveness 1
  test "${BOOTSTRAP_PID_LIVENESS}" = active
' _ "${BOOTSTRAP_LIB}"
assert_cmd "PID classifier treats kill EPERM plus full ps membership as active" bash -c '
  source "$1"
  kill() { return 1; }
  ps() {
    test "$*" = "-A -o pid=" || return 2
    printf "  1\n  77\n"
  }
  bootstrap_pid_liveness 77
  test "${BOOTSTRAP_PID_LIVENESS}" = active
' _ "${BOOTSTRAP_LIB}"
assert_cmd "PID classifier proves absence from a complete ps table as dead" bash -c '
  source "$1"
  kill() { return 1; }
  ps() {
    test "$*" = "-A -o pid=" || return 2
    printf "1\n77\n"
  }
  bootstrap_pid_liveness 88
  test "${BOOTSTRAP_PID_LIVENESS}" = dead
' _ "${BOOTSTRAP_LIB}"
assert_cmd "PID classifier keeps empty ps exit 1 conservatively ambiguous" bash -c '
  source "$1"
  kill() { return 1; }
  ps() { return 1; }
  bootstrap_pid_liveness 99
  test "${BOOTSTRAP_PID_LIVENESS}" = ambiguous
' _ "${BOOTSTRAP_LIB}"
assert_cmd "PID classifier keeps empty ps exit 2 conservatively ambiguous" bash -c '
  source "$1"
  kill() { return 1; }
  ps() { return 2; }
  bootstrap_pid_liveness 99
  test "${BOOTSTRAP_PID_LIVENESS}" = ambiguous
' _ "${BOOTSTRAP_LIB}"
for invalid_pid_table in empty header malformed duplicate; do
  assert_cmd "PID classifier rejects ${invalid_pid_table} full ps table" bash -c '
    source "$1"
    table_kind="$2"
    kill() { return 1; }
    ps() {
      test "$*" = "-A -o pid=" || return 2
      case "${table_kind}" in
        empty) printf "" ;;
        header) printf "PID\n1\n" ;;
        malformed) printf "1 two\n" ;;
        duplicate) printf "1\n1\n" ;;
      esac
    }
    bootstrap_pid_liveness 99
    test "${BOOTSTRAP_PID_LIVENESS}" = ambiguous
  ' _ "${BOOTSTRAP_LIB}" "${invalid_pid_table}"
done
mkdir -p "$(dirname "${active_lock_dir}")"
printf 'pid=%s\nnonce=active-owner\n' "$$" > "${active_lock_dir}"
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
  grep -qFx "nonce=active-owner" "${active_lock_dir}"
assert_cmd "active lock conflict performs no download or install" \
  test ! -e "${active_lock_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}"

ambiguous_lock_home="${TMP_HOME}/bootstrap-ambiguous-lock-home"
ambiguous_lock_dir="${ambiguous_lock_home}/.vibeguard/dist/.bootstrap.lock"
ambiguous_lock_bin="${TMP_HOME}/bootstrap-ambiguous-lock-bin"
mkdir -p "$(dirname "${ambiguous_lock_dir}")" "${ambiguous_lock_bin}"
printf 'pid=99999999\nnonce=ambiguous-owner\n' > "${ambiguous_lock_dir}"
cat > "${ambiguous_lock_bin}/ps" <<'SH'
#!/usr/bin/env bash
exit 2
SH
chmod +x "${ambiguous_lock_bin}/ps"
ambiguous_lock_rc=0
ambiguous_lock_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${ambiguous_lock_home}" \
    PATH="${ambiguous_lock_bin}:${PATH}" \
    VIBEGUARD_TEST_RELEASE_DIR="${handoff_release}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes 2>&1
)" || ambiguous_lock_rc=$?
assert_cmd "bootstrap refuses a lock whose PID state cannot be proven" \
  test "${ambiguous_lock_rc}" -eq 73
assert_contains "${ambiguous_lock_out}" "cannot prove lock owner pid=99999999 is dead" \
  "ambiguous PID state fails closed visibly"
assert_cmd "ambiguous PID state preserves the exact foreign lock" \
  grep -qFx "nonce=ambiguous-owner" "${ambiguous_lock_dir}"
assert_cmd "ambiguous PID state performs no download or install" \
  test ! -e "${ambiguous_lock_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}"

pid_reuse_home="${TMP_HOME}/bootstrap-pid-reuse-home"
pid_reuse_dir="${pid_reuse_home}/.vibeguard/dist/.bootstrap.lock"
pid_reuse_bin="${TMP_HOME}/bootstrap-pid-reuse-bin"
pid_reuse_count="${TMP_HOME}/bootstrap-pid-reuse.count"
mkdir -p "$(dirname "${pid_reuse_dir}")" "${pid_reuse_bin}"
printf 'pid=99999998\nnonce=pid-reuse-owner\n' > "${pid_reuse_dir}"
printf '0\n' > "${pid_reuse_count}"
cat > "${pid_reuse_bin}/ps" <<SH
#!/usr/bin/env bash
count="\$(cat "${pid_reuse_count}")"
count="\$((count + 1))"
printf '%s\n' "\${count}" > "${pid_reuse_count}"
if [[ "\${count}" -eq 1 ]]; then
  printf '1\\n2\\n'
  exit 0
fi
printf '1\\n99999998\\n'
SH
chmod +x "${pid_reuse_bin}/ps"
pid_reuse_rc=0
pid_reuse_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${pid_reuse_home}" \
    PATH="${pid_reuse_bin}:${PATH}" \
    VIBEGUARD_TEST_RELEASE_DIR="${handoff_release}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes 2>&1
)" || pid_reuse_rc=$?
assert_cmd "bootstrap rejects PID reuse detected after exact owner claim" \
  test "${pid_reuse_rc}" -eq 73
assert_contains "${pid_reuse_out}" "no longer proven dead" \
  "post-claim PID reuse is fail-closed"
assert_cmd "PID reuse restores and preserves the exact claimed lock" bash -c \
  'test -f "$1" && grep -qFx "nonce=pid-reuse-owner" "$1" && test "$(cat "$2")" -eq 2' _ \
  "${pid_reuse_dir}" "${pid_reuse_count}"
assert_cmd "PID reuse performs no download or install" \
  test ! -e "${pid_reuse_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}"

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
mkdir -p "$(dirname "${stale_race_dir}")" "${stale_race_bin}"
printf 'pid=%s\nnonce=dead-race-owner\n' "${dead_lock_pid}" > "${stale_race_dir}"
cat > "${stale_race_bin}/mv" <<SH
#!/usr/bin/env bash
previous=""
last=""
for arg in "\$@"; do
  previous="\${last}"
  last="\${arg}"
done
if [[ "\${previous}" == "${stale_race_dir}" ]]; then
  printf 'pid=%s\\nnonce=racing-active-owner\\n' "$$" > "${stale_race_dir}"
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
  "stale-owner race is detected after the atomic rename"
assert_cmd "stale-owner race preserves the replacement active owner" bash -c \
  'test -f "$1" && grep -qFx "nonce=racing-active-owner" "$1"' _ \
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
assert_contains "${missing_owner_out}" "lock owner metadata must be a regular file" \
  "missing legacy owner is rejected because inactivity cannot be proven"
assert_cmd "missing legacy owner lock is preserved" test -d "${missing_owner_dir}"

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
  "malformed legacy owner is rejected because inactivity cannot be proven"
assert_cmd "malformed legacy owner lock is preserved exactly" \
  grep -qFx "pid=not-a-pid" "${malformed_owner_dir}/owner"

symlink_owner_home="${TMP_HOME}/bootstrap-symlink-owner-home"
symlink_owner_dir="${symlink_owner_home}/.vibeguard/dist/.bootstrap.lock"
symlink_owner_foreign="${TMP_HOME}/bootstrap-symlink-owner.foreign"
mkdir -p "$(dirname "${symlink_owner_dir}")"
printf 'pid=%s\nnonce=symlink-foreign\n' "$$" > "${symlink_owner_foreign}"
ln -s "${symlink_owner_foreign}" "${symlink_owner_dir}"
symlink_owner_rc=0
symlink_owner_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${symlink_owner_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${BOOTSTRAP_RELEASE}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --dry-run --yes 2>&1
)" || symlink_owner_rc=$?
assert_cmd "bootstrap fails closed on a symlink lock" \
  test "${symlink_owner_rc}" -eq 73
assert_contains "${symlink_owner_out}" "bootstrap lock must not be a symlink" \
  "symlink lock failure is explicit"
assert_cmd "symlink lock failure preserves foreign target" \
  grep -qFx "nonce=symlink-foreign" "${symlink_owner_foreign}"

clean_home="${TMP_HOME}/bootstrap-clean-home"
mkdir -p "${clean_home}"
assert_cmd "bootstrap fixture install prepares executable payload state for clean" \
  env "${bootstrap_base_env[@]}" \
  HOME="${clean_home}" \
  VIBEGUARD_TEST_RELEASE_DIR="${argv_release}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes
assert_cmd "bootstrap fixture install selected its executable payload" bash -c \
  'test -d "$1" && test -L "$2" && test "$(readlink "$2")" = "$3" && test -f "$4"' _ \
  "${clean_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}" \
  "${clean_home}/.vibeguard/dist/current" \
  "${BOOTSTRAP_VERSION}" \
  "${clean_home}/.vibeguard/dist/.bootstrap-transaction-${BOOTSTRAP_VERSION}"
for clean_attempt in 1 2; do
  clean_rc=0
  clean_out="$(
    env "${bootstrap_base_env[@]}" \
      HOME="${clean_home}" \
      VIBEGUARD_TEST_RELEASE_DIR="${argv_release}" \
      bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --clean 2>&1
  )" || clean_rc=$?
  assert_cmd "bootstrap clean attempt ${clean_attempt} succeeds" test "${clean_rc}" -eq 0
  assert_contains "${clean_out}" "ARGV[0]=--clean" \
    "bootstrap clean attempt ${clean_attempt} executes the verified staged cleaner"
  assert_cmd "bootstrap clean attempt ${clean_attempt} commits no executable payload state" bash -c \
    'test ! -e "$1" && test ! -L "$1" && test ! -e "$2" && test ! -e "$3"' _ \
    "${clean_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}" \
    "${clean_home}/.vibeguard/dist/current" \
    "${clean_home}/.vibeguard/dist/.bootstrap-transaction-${BOOTSTRAP_VERSION}"
done

clean_help_home="${TMP_HOME}/bootstrap-clean-help-home"
mkdir -p "${clean_help_home}"
env "${bootstrap_base_env[@]}" \
  HOME="${clean_help_home}" \
  VIBEGUARD_TEST_RELEASE_DIR="${argv_release}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes >/dev/null
clean_help_before="$(
  shasum -a 256 \
    "${clean_help_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}/.vibeguard-payload" \
    "${clean_help_home}/.vibeguard/dist/.bootstrap-transaction-${BOOTSTRAP_VERSION}"
)"
clean_help_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${clean_help_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${argv_release}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- \
      --clean --purge-data --help 2>&1
)"
assert_contains "${clean_help_out}" "ARGV[0]=--clean" \
  "clean help executes only the verified staged help path"
assert_cmd "clean help preserves selected payload and transaction byte-for-byte" bash -c \
  'test "$(readlink "$1")" = "$2" && test "$(shasum -a 256 "$3" "$4")" = "$5"' _ \
  "${clean_help_home}/.vibeguard/dist/current" "${BOOTSTRAP_VERSION}" \
  "${clean_help_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}/.vibeguard-payload" \
  "${clean_help_home}/.vibeguard/dist/.bootstrap-transaction-${BOOTSTRAP_VERSION}" \
  "${clean_help_before}"

cross_clean_home="${TMP_HOME}/bootstrap-cross-version-clean-home"
cross_clean_version="9.9.8"
mkdir -p "${cross_clean_home}"
env "${bootstrap_base_env[@]}" \
  HOME="${cross_clean_home}" \
  VIBEGUARD_TEST_RELEASE_DIR="${argv_release}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes >/dev/null
mv "${cross_clean_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}" \
  "${cross_clean_home}/.vibeguard/dist/${cross_clean_version}"
sed -e "s/^version=.*/version=${cross_clean_version}/" \
  "${cross_clean_home}/.vibeguard/dist/${cross_clean_version}/.vibeguard-payload" \
  > "${cross_clean_home}/.vibeguard/dist/${cross_clean_version}/.vibeguard-payload.next"
mv "${cross_clean_home}/.vibeguard/dist/${cross_clean_version}/.vibeguard-payload.next" \
  "${cross_clean_home}/.vibeguard/dist/${cross_clean_version}/.vibeguard-payload"
printf '%s\n' "${cross_clean_version}" \
  > "${cross_clean_home}/.vibeguard/dist/${cross_clean_version}/vibeguard-runtime/VERSION"
mv "${cross_clean_home}/.vibeguard/dist/.bootstrap-transaction-${BOOTSTRAP_VERSION}" \
  "${cross_clean_home}/.vibeguard/dist/.bootstrap-transaction-${cross_clean_version}"
sed -e "s/^version=.*/version=${cross_clean_version}/" \
  "${cross_clean_home}/.vibeguard/dist/.bootstrap-transaction-${cross_clean_version}" \
  > "${cross_clean_home}/.vibeguard/dist/.bootstrap-transaction-${cross_clean_version}.next"
mv "${cross_clean_home}/.vibeguard/dist/.bootstrap-transaction-${cross_clean_version}.next" \
  "${cross_clean_home}/.vibeguard/dist/.bootstrap-transaction-${cross_clean_version}"
rm -f "${cross_clean_home}/.vibeguard/dist/current"
ln -s "${cross_clean_version}" "${cross_clean_home}/.vibeguard/dist/current"
env "${bootstrap_base_env[@]}" \
  HOME="${cross_clean_home}" \
  VIBEGUARD_TEST_RELEASE_DIR="${argv_release}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --clean >/dev/null
assert_cmd "older launcher clean removes the verified active bootstrap payload" bash -c \
  'test ! -e "$1" && test ! -L "$1" && test ! -e "$2" && test ! -e "$3"' _ \
  "${cross_clean_home}/.vibeguard/dist/current" \
  "${cross_clean_home}/.vibeguard/dist/${cross_clean_version}" \
  "${cross_clean_home}/.vibeguard/dist/.bootstrap-transaction-${cross_clean_version}"

history_clean_home="${TMP_HOME}/bootstrap-history-clean-home"
history_clean_version="9.9.7"
history_unmanaged_version="9.9.6"
mkdir -p "${history_clean_home}"
env "${bootstrap_base_env[@]}" \
  HOME="${history_clean_home}" \
  VIBEGUARD_TEST_RELEASE_DIR="${argv_release}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes >/dev/null
cp -R "${history_clean_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}" \
  "${history_clean_home}/.vibeguard/dist/${history_clean_version}"
sed -e "s/^version=.*/version=${history_clean_version}/" \
  "${history_clean_home}/.vibeguard/dist/${history_clean_version}/.vibeguard-payload" \
  > "${history_clean_home}/.vibeguard/dist/${history_clean_version}/.vibeguard-payload.next"
mv "${history_clean_home}/.vibeguard/dist/${history_clean_version}/.vibeguard-payload.next" \
  "${history_clean_home}/.vibeguard/dist/${history_clean_version}/.vibeguard-payload"
printf '%s\n' "${history_clean_version}" \
  > "${history_clean_home}/.vibeguard/dist/${history_clean_version}/vibeguard-runtime/VERSION"
sed -e "s/^version=.*/version=${history_clean_version}/" \
  "${history_clean_home}/.vibeguard/dist/.bootstrap-transaction-${BOOTSTRAP_VERSION}" \
  > "${history_clean_home}/.vibeguard/dist/.bootstrap-transaction-${history_clean_version}"
mkdir -p "${history_clean_home}/.vibeguard/dist/${history_unmanaged_version}"
printf 'unmanaged\n' \
  > "${history_clean_home}/.vibeguard/dist/${history_unmanaged_version}/sentinel"
history_clean_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${history_clean_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${argv_release}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --clean 2>&1
)"
assert_cmd "bootstrap clean removes every transaction-owned payload version" bash -c \
  'test ! -e "$1" && test ! -e "$2" && test ! -e "$3" && test ! -e "$4"' _ \
  "${history_clean_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}" \
  "${history_clean_home}/.vibeguard/dist/.bootstrap-transaction-${BOOTSTRAP_VERSION}" \
  "${history_clean_home}/.vibeguard/dist/${history_clean_version}" \
  "${history_clean_home}/.vibeguard/dist/.bootstrap-transaction-${history_clean_version}"
assert_contains "${history_clean_out}" \
  "Preserving unowned distribution directory: ${history_unmanaged_version}" \
  "bootstrap clean reports unowned historical payload preservation"
assert_cmd "bootstrap clean preserves an unowned semver directory" \
  grep -qFx "unmanaged" \
  "${history_clean_home}/.vibeguard/dist/${history_unmanaged_version}/sentinel"

clean_cleanup_home="${TMP_HOME}/bootstrap-clean-cleanup-failure-home"
clean_cleanup_bin="${TMP_HOME}/bootstrap-clean-cleanup-failure-bin"
clean_cleanup_marker="${TMP_HOME}/bootstrap-clean-cleanup-failure.marker"
clean_cleanup_real_rm="$(command -v rm)"
mkdir -p "${clean_cleanup_home}" "${clean_cleanup_bin}"
cat > "${clean_cleanup_bin}/rm" <<SH
#!/usr/bin/env bash
last=""
for arg in "\$@"; do last="\${arg}"; done
if [[ "\${last}" == "${clean_cleanup_home}/.vibeguard/dist/.bootstrap-${BOOTSTRAP_VERSION}."* \
  && ! -e "${clean_cleanup_marker}" ]]; then
  : > "${clean_cleanup_marker}"
  exit 1
fi
exec "${clean_cleanup_real_rm}" "\$@"
SH
chmod +x "${clean_cleanup_bin}/rm"
clean_cleanup_rc=0
env "${bootstrap_base_env[@]}" \
  HOME="${clean_cleanup_home}" \
  PATH="${clean_cleanup_bin}:${PATH}" \
  VIBEGUARD_TEST_RELEASE_DIR="${argv_release}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --clean \
  >/dev/null 2>&1 || clean_cleanup_rc=$?
assert_cmd "clean propagates fallible final cleanup instead of exiting zero" \
  test "${clean_cleanup_rc}" -ne 0
assert_cmd "clean cleanup failure still releases the exact bootstrap lock" \
  test ! -e "${clean_cleanup_home}/.vibeguard/dist/.bootstrap.lock"

for clean_crash_point in before-current after-current after-final; do
  clean_crash_home="${TMP_HOME}/bootstrap-clean-crash-${clean_crash_point}-home"
  clean_crash_bin="${TMP_HOME}/bootstrap-clean-crash-${clean_crash_point}-bin"
  clean_crash_marker="${TMP_HOME}/bootstrap-clean-crash-${clean_crash_point}.marker"
  clean_crash_real_rm="$(command -v rm)"
  mkdir -p "${clean_crash_home}" "${clean_crash_bin}"
  env "${bootstrap_base_env[@]}" \
    HOME="${clean_crash_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${argv_release}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes \
    >/dev/null
  cat > "${clean_crash_bin}/rm" <<SH
#!/usr/bin/env bash
last=""
for arg in "\$@"; do last="\${arg}"; done
current="${clean_crash_home}/.vibeguard/dist/current"
final="${clean_crash_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}"
if [[ ! -e "${clean_crash_marker}" ]]; then
  case "${clean_crash_point}" in
    before-current)
      if [[ "\${last}" == "\${current}" ]]; then
        : > "${clean_crash_marker}"
        kill -KILL "\${PPID}"
        exit 137
      fi
      ;;
    after-current)
      if [[ "\${last}" == "\${current}" ]]; then
        "${clean_crash_real_rm}" "\$@"
        : > "${clean_crash_marker}"
        kill -KILL "\${PPID}"
        exit 137
      fi
      ;;
    after-final)
      if [[ "\${last}" == "\${final}" ]]; then
        "${clean_crash_real_rm}" "\$@"
        : > "${clean_crash_marker}"
        kill -KILL "\${PPID}"
        exit 137
      fi
      ;;
  esac
fi
exec "${clean_crash_real_rm}" "\$@"
SH
  chmod +x "${clean_crash_bin}/rm"
  clean_crash_rc=0
  env "${bootstrap_base_env[@]}" \
    HOME="${clean_crash_home}" \
    PATH="${clean_crash_bin}:${PATH}" \
    VIBEGUARD_TEST_RELEASE_DIR="${argv_release}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --clean \
    >/dev/null 2>&1 || clean_crash_rc=$?
  assert_cmd "clean crash ${clean_crash_point} exits nonzero" \
    test "${clean_crash_rc}" -ne 0
  assert_cmd "clean crash ${clean_crash_point} persists cleaning tombstone" \
    grep -qFx "phase=cleaning" \
    "${clean_crash_home}/.vibeguard/dist/.bootstrap-transaction-${BOOTSTRAP_VERSION}"
  case "${clean_crash_point}" in
    before-current)
      assert_cmd "clean crash before current deletion preserves current and final" bash -c \
        'test -L "$1" && test -d "$2"' _ \
        "${clean_crash_home}/.vibeguard/dist/current" \
        "${clean_crash_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}"
      cleaning_nonclean_rc=0
      cleaning_nonclean_out="$(
        env "${bootstrap_base_env[@]}" \
          HOME="${clean_crash_home}" \
          VIBEGUARD_TEST_RELEASE_DIR="${argv_release}" \
          bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes 2>&1
      )" || cleaning_nonclean_rc=$?
      assert_cmd "non-clean retry refuses an interrupted cleaning transaction" \
        test "${cleaning_nonclean_rc}" -eq 73
      assert_contains "${cleaning_nonclean_out}" "rerun the same --clean" \
        "non-clean retry reports the required cleaning recovery"
      assert_cmd "non-clean retry preserves cleaning tombstone and payload" bash -c \
        'grep -qFx "phase=cleaning" "$1" && test -L "$2" && test -d "$3"' _ \
        "${clean_crash_home}/.vibeguard/dist/.bootstrap-transaction-${BOOTSTRAP_VERSION}" \
        "${clean_crash_home}/.vibeguard/dist/current" \
        "${clean_crash_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}"
      ;;
    after-current)
      assert_cmd "clean crash after current deletion preserves only final" bash -c \
        'test ! -e "$1" && test ! -L "$1" && test -d "$2"' _ \
        "${clean_crash_home}/.vibeguard/dist/current" \
        "${clean_crash_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}"
      ;;
    after-final)
      assert_cmd "clean crash after final deletion leaves only tombstone" bash -c \
        'test ! -e "$1" && test ! -L "$1" && test ! -e "$2"' _ \
        "${clean_crash_home}/.vibeguard/dist/current" \
        "${clean_crash_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}"
      ;;
  esac
  clean_crash_retry_rc=0
  env "${bootstrap_base_env[@]}" \
    HOME="${clean_crash_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${argv_release}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --clean \
    >/dev/null 2>&1 || clean_crash_retry_rc=$?
  assert_cmd "clean retry ${clean_crash_point} completes idempotently" \
    test "${clean_crash_retry_rc}" -eq 0
  assert_cmd "clean retry ${clean_crash_point} removes payload and tombstone" bash -c \
    'test ! -e "$1" && test ! -L "$1" && test ! -e "$2" && test ! -e "$3"' _ \
    "${clean_crash_home}/.vibeguard/dist/current" \
    "${clean_crash_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}" \
    "${clean_crash_home}/.vibeguard/dist/.bootstrap-transaction-${BOOTSTRAP_VERSION}"
done

lock_crash_before_home="${TMP_HOME}/bootstrap-lock-crash-before-home"
lock_crash_before_bin="${TMP_HOME}/bootstrap-lock-crash-before-bin"
lock_crash_real_ln="$(command -v ln)"
mkdir -p "${lock_crash_before_home}" "${lock_crash_before_bin}"
cat > "${lock_crash_before_bin}/ln" <<SH
#!/usr/bin/env bash
last=""
for arg in "\$@"; do last="\${arg}"; done
if [[ "\${last}" == "${lock_crash_before_home}/.vibeguard/dist/.bootstrap.lock" ]]; then
  kill -KILL "\${PPID}"
  exit 137
fi
exec "${lock_crash_real_ln}" "\$@"
SH
chmod +x "${lock_crash_before_bin}/ln"
lock_crash_before_rc=0
env "${bootstrap_base_env[@]}" \
  HOME="${lock_crash_before_home}" \
  PATH="${lock_crash_before_bin}:${PATH}" \
  VIBEGUARD_TEST_RELEASE_DIR="${handoff_release}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes \
  >/dev/null 2>&1 || lock_crash_before_rc=$?
assert_cmd "crash before atomic lock publish exits nonzero" \
  test "${lock_crash_before_rc}" -ne 0
assert_cmd "crash before atomic lock publish leaves no blocking lock" \
  test ! -e "${lock_crash_before_home}/.vibeguard/dist/.bootstrap.lock"
assert_cmd "retry after pre-publish lock crash succeeds" env "${bootstrap_base_env[@]}" \
  HOME="${lock_crash_before_home}" \
  VIBEGUARD_TEST_RELEASE_DIR="${handoff_release}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes

lock_crash_after_home="${TMP_HOME}/bootstrap-lock-crash-after-home"
lock_crash_after_bin="${TMP_HOME}/bootstrap-lock-crash-after-bin"
mkdir -p "${lock_crash_after_home}" "${lock_crash_after_bin}"
cat > "${lock_crash_after_bin}/ln" <<SH
#!/usr/bin/env bash
last=""
for arg in "\$@"; do last="\${arg}"; done
if [[ "\${last}" == "${lock_crash_after_home}/.vibeguard/dist/.bootstrap.lock" ]]; then
  "${lock_crash_real_ln}" "\$@"
  kill -KILL "\${PPID}"
  exit 137
fi
exec "${lock_crash_real_ln}" "\$@"
SH
chmod +x "${lock_crash_after_bin}/ln"
lock_crash_after_rc=0
env "${bootstrap_base_env[@]}" \
  HOME="${lock_crash_after_home}" \
  PATH="${lock_crash_after_bin}:${PATH}" \
  VIBEGUARD_TEST_RELEASE_DIR="${handoff_release}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes \
  >/dev/null 2>&1 || lock_crash_after_rc=$?
assert_cmd "crash after atomic lock publish exits nonzero" \
  test "${lock_crash_after_rc}" -ne 0
assert_cmd "crash after atomic lock publish leaves complete owner metadata" bash -c \
  'test -f "$1" && grep -qE "^pid=[1-9][0-9]*$" "$1" && grep -qE "^nonce=[A-Za-z0-9._-]+$" "$1"' _ \
  "${lock_crash_after_home}/.vibeguard/dist/.bootstrap.lock"
assert_cmd "retry reaps atomically published stale lock and succeeds" env "${bootstrap_base_env[@]}" \
  HOME="${lock_crash_after_home}" \
  VIBEGUARD_TEST_RELEASE_DIR="${handoff_release}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes

prepared_crash_home="${TMP_HOME}/bootstrap-prepared-crash-home"
prepared_crash_bin="${TMP_HOME}/bootstrap-prepared-crash-bin"
prepared_crash_marker="${TMP_HOME}/bootstrap-prepared-crash.marker"
mkdir -p "${prepared_crash_home}" "${prepared_crash_bin}"
cat > "${prepared_crash_bin}/mv" <<SH
#!/usr/bin/env bash
previous=""
last=""
for arg in "\$@"; do previous="\${last}"; last="\${arg}"; done
transaction="${prepared_crash_home}/.vibeguard/dist/.bootstrap-transaction-${BOOTSTRAP_VERSION}"
if [[ "\${previous}" == */.bootstrap-transaction-write.* \
  && "\${last}" == "\${transaction}" && ! -e "${prepared_crash_marker}" ]]; then
  "${switch_failure_real_mv}" "\$@"
  : > "${prepared_crash_marker}"
  kill -KILL "\${PPID}"
  exit 137
fi
exec "${switch_failure_real_mv}" "\$@"
SH
chmod +x "${prepared_crash_bin}/mv"
prepared_crash_rc=0
env "${bootstrap_base_env[@]}" \
  HOME="${prepared_crash_home}" \
  PATH="${prepared_crash_bin}:${PATH}" \
  VIBEGUARD_TEST_RELEASE_DIR="${handoff_release}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes \
  >/dev/null 2>&1 || prepared_crash_rc=$?
assert_cmd "SIGKILL after prepared transaction write exits nonzero" \
  test "${prepared_crash_rc}" -ne 0
assert_cmd "prepared-write crash leaves transaction without final payload" bash -c \
  'grep -qFx "phase=prepared" "$1" && test ! -e "$2" && test -f "$3"' _ \
  "${prepared_crash_home}/.vibeguard/dist/.bootstrap-transaction-${BOOTSTRAP_VERSION}" \
  "${prepared_crash_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}" \
  "${prepared_crash_home}/.vibeguard/dist/.bootstrap.lock"
prepared_retry_rc=0
prepared_retry_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${prepared_crash_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${handoff_release}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes 2>&1
)" || prepared_retry_rc=$?
assert_cmd "retry publishes verified payload after prepared-write crash" \
  test "${prepared_retry_rc}" -eq 0
assert_contains "${prepared_retry_out}" "Resuming verified bootstrap transaction phase=prepared" \
  "prepared-write retry reports safe publish recovery"
assert_cmd "prepared-write retry commits payload transaction" \
  grep -qFx "phase=committed" \
  "${prepared_crash_home}/.vibeguard/dist/.bootstrap-transaction-${BOOTSTRAP_VERSION}"

stage_crash_home="${TMP_HOME}/bootstrap-stage-crash-home"
stage_crash_bin="${TMP_HOME}/bootstrap-stage-crash-bin"
mkdir -p "${stage_crash_home}" "${stage_crash_bin}"
cat > "${stage_crash_bin}/mv" <<SH
#!/usr/bin/env bash
previous=""
last=""
for arg in "\$@"; do previous="\${last}"; last="\${arg}"; done
if [[ "\${previous}" == */stage && "\${last}" == "${stage_crash_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}" ]]; then
  "${switch_failure_real_mv}" "\$@"
  kill -KILL "\${PPID}"
  exit 137
fi
exec "${switch_failure_real_mv}" "\$@"
SH
chmod +x "${stage_crash_bin}/mv"
stage_crash_rc=0
env "${bootstrap_base_env[@]}" \
  HOME="${stage_crash_home}" \
  PATH="${stage_crash_bin}:${PATH}" \
  VIBEGUARD_TEST_RELEASE_DIR="${handoff_release}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes \
  >/dev/null 2>&1 || stage_crash_rc=$?
assert_cmd "SIGKILL after final payload move exits nonzero" test "${stage_crash_rc}" -ne 0
assert_cmd "SIGKILL after final move retains prepared repair evidence" bash -c \
  'test -d "$1" && grep -qFx "phase=prepared" "$2" && test -f "$3"' _ \
  "${stage_crash_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}" \
  "${stage_crash_home}/.vibeguard/dist/.bootstrap-transaction-${BOOTSTRAP_VERSION}" \
  "${stage_crash_home}/.vibeguard/dist/.bootstrap.lock"
stage_retry_rc=0
stage_retry_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${stage_crash_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${handoff_release}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes 2>&1
)" || stage_retry_rc=$?
assert_cmd "retry resumes after SIGKILL final-move crash" test "${stage_retry_rc}" -eq 0
assert_contains "${stage_retry_out}" "Resuming verified bootstrap transaction phase=prepared" \
  "SIGKILL retry reports its persisted prepared phase"
assert_cmd "SIGKILL retry commits setup and releases lock" bash -c \
  'grep -qFx "phase=committed" "$1" && test ! -e "$2"' _ \
  "${stage_crash_home}/.vibeguard/dist/.bootstrap-transaction-${BOOTSTRAP_VERSION}" \
  "${stage_crash_home}/.vibeguard/dist/.bootstrap.lock"

for missing_final_phase in setup committed; do
  missing_final_home="${TMP_HOME}/bootstrap-missing-final-${missing_final_phase}-home"
  mkdir -p "${missing_final_home}"
  env "${bootstrap_base_env[@]}" \
    HOME="${missing_final_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${handoff_release}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes \
    >/dev/null
  missing_final_transaction="${missing_final_home}/.vibeguard/dist/.bootstrap-transaction-${BOOTSTRAP_VERSION}"
  sed -e "s/^phase=.*/phase=${missing_final_phase}/" \
    "${missing_final_transaction}" > "${missing_final_transaction}.next"
  mv "${missing_final_transaction}.next" "${missing_final_transaction}"
  rm -rf "${missing_final_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}"
  missing_final_rc=0
  missing_final_out="$(
    env "${bootstrap_base_env[@]}" \
      HOME="${missing_final_home}" \
      VIBEGUARD_TEST_RELEASE_DIR="${handoff_release}" \
      bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes 2>&1
  )" || missing_final_rc=$?
  assert_cmd "${missing_final_phase} transaction without final fails closed" \
    test "${missing_final_rc}" -eq 73
  assert_contains "${missing_final_out}" "without its distribution" \
    "${missing_final_phase} missing-final failure is explicit"
done

scheduler_release="${TMP_HOME}/bootstrap-release-scheduler"
scheduler_payload_root="${TMP_HOME}/bootstrap-release-scheduler-root"
mkdir -p "${scheduler_release}" "${scheduler_payload_root}"
cp "${BOOTSTRAP_RELEASE}"/vibeguard-runtime-* "${scheduler_release}/"
tar -xzf "${BOOTSTRAP_RELEASE}/${BOOTSTRAP_ASSET}" -C "${scheduler_payload_root}"
cp "${REPO_DIR}/scripts/setup/install.sh" \
  "${scheduler_payload_root}/scripts/setup/install.sh"
cp "${REPO_DIR}/scripts/setup/check.sh" \
  "${scheduler_payload_root}/scripts/setup/check.sh"
cp "${REPO_DIR}/scripts/setup/clean.sh" \
  "${scheduler_payload_root}/scripts/setup/clean.sh"
cp "${REPO_DIR}/scripts/setup/lib.sh" \
  "${scheduler_payload_root}/scripts/setup/lib.sh"
cp "${REPO_DIR}/scripts/install-systemd.sh" \
  "${scheduler_payload_root}/scripts/install-systemd.sh"
python3 - "${scheduler_release}/${BOOTSTRAP_ASSET}" "${scheduler_payload_root}" <<'PY'
import pathlib
import sys
import tarfile

archive = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
with tarfile.open(archive, "w:gz") as handle:
    for child in sorted(root.iterdir()):
        handle.add(child, arcname=child.name, recursive=True)
PY
{
  for scheduler_asset_path in "${scheduler_release}"/vibeguard-runtime-* \
    "${scheduler_release}/${BOOTSTRAP_ASSET}"; do
    scheduler_asset_name="${scheduler_asset_path##*/}"
    scheduler_asset_sha="$(shasum -a 256 "${scheduler_asset_path}" | awk '{print $1}')"
    printf '%s  %s\n' "${scheduler_asset_sha}" "${scheduler_asset_name}"
  done
} | LC_ALL=C sort -k2,2 > "${scheduler_release}/SHA256SUMS"

direct_payload_scheduler_home="${TMP_HOME}/direct-payload-scheduler-home"
direct_payload_scheduler_service="${direct_payload_scheduler_home}/.config/systemd/user/vibeguard-gc.service"
mkdir -p "${direct_payload_scheduler_home}"
direct_payload_scheduler_rc=0
HOME="${direct_payload_scheduler_home}" \
  VIBEGUARD_TEST_UNAME=Linux \
  VIBEGUARD_TEST_RELEASE_DIR="${scheduler_release}" \
  bash "${scheduler_payload_root}/setup.sh" --yes --with-scheduler \
  >/dev/null 2>&1 || direct_payload_scheduler_rc=$?
assert_cmd "direct unpacked payload installs opted-in scheduler without dist/current" \
  test "${direct_payload_scheduler_rc}" -eq 0
assert_cmd "direct payload scheduler targets its verified payload root" \
  grep -qF "${scheduler_payload_root}/scripts/gc/gc-scheduled.sh" \
  "${direct_payload_scheduler_service}"

scheduler_home="${TMP_HOME}/bootstrap-scheduler-home"
scheduler_unit_dir="${scheduler_home}/.config/systemd/user"
scheduler_service="${scheduler_unit_dir}/vibeguard-gc.service"
scheduler_timer="${scheduler_unit_dir}/vibeguard-gc.timer"
mkdir -p "${scheduler_home}"
scheduler_first_rc=0
scheduler_first_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${scheduler_home}" \
    VIBEGUARD_TEST_UNAME=Linux \
    VIBEGUARD_TEST_RELEASE_DIR="${scheduler_release}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes --with-scheduler 2>&1
)" || scheduler_first_rc=$?
assert_cmd "payload bootstrap installs opted-in systemd scheduler" \
  test "${scheduler_first_rc}" -eq 0
assert_contains "${scheduler_first_out}" "Scheduled GC installed via systemd" \
  "payload scheduler install reports successful managed ownership"
assert_cmd "payload systemd scheduler targets stable current selection" \
  grep -qF "${scheduler_home}/.vibeguard/dist/current/scripts/gc/gc-scheduled.sh" \
  "${scheduler_service}"
assert_cmd "payload systemd scheduler records exact ownership hashes" bash -c \
  'grep -qFx "schema=1" "$1" && grep -qFx "kind=systemd" "$1" && grep -qFx "phase=managed" "$1" && grep -qE "^service_sha256=[0-9a-f]{64}$" "$1" && grep -qE "^timer_sha256=[0-9a-f]{64}$" "$1"' _ \
  "${scheduler_home}/.vibeguard/scheduler-ownership"
sed -e "s|dist/current/scripts/gc|dist/${BOOTSTRAP_VERSION}/scripts/gc|g" \
  "${scheduler_service}" > "${scheduler_service}.old"
mv "${scheduler_service}.old" "${scheduler_service}"
printf 'schema=1\nkind=systemd\nservice_sha256=%s\ntimer_sha256=%s\n' \
  "$(shasum -a 256 "${scheduler_service}" | awk '{print $1}')" \
  "$(shasum -a 256 "${scheduler_timer}" | awk '{print $1}')" \
  > "${scheduler_home}/.vibeguard/scheduler-ownership"
scheduler_retry_rc=0
scheduler_retry_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${scheduler_home}" \
    VIBEGUARD_TEST_UNAME=Linux \
    VIBEGUARD_TEST_RELEASE_DIR="${scheduler_release}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes 2>&1
)" || scheduler_retry_rc=$?
assert_cmd "default payload retry refreshes an existing managed scheduler" \
  test "${scheduler_retry_rc}" -eq 0
assert_contains "${scheduler_retry_out}" "Mode: refresh managed scheduler" \
  "managed scheduler refresh is explicit"
assert_cmd "managed scheduler refresh removes the old version-specific target" bash -c \
  'grep -qF "$2/dist/current/scripts/gc/gc-scheduled.sh" "$1" && ! grep -qF "$2/dist/$3/scripts/gc/gc-scheduled.sh" "$1"' _ \
  "${scheduler_service}" "${scheduler_home}/.vibeguard" "${BOOTSTRAP_VERSION}"

wrong_systemd_before="$(
  shasum -a 256 "${scheduler_service}" "${scheduler_timer}" \
    "${scheduler_home}/.vibeguard/scheduler-ownership"
)"
wrong_systemd_rc=0
wrong_systemd_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${scheduler_home}" \
    VIBEGUARD_TEST_UNAME=Darwin \
    VIBEGUARD_TEST_RELEASE_DIR="${scheduler_release}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes 2>&1
)" || wrong_systemd_rc=$?
assert_cmd "Darwin payload retry preserves a Linux scheduler HOME" \
  test "${wrong_systemd_rc}" -eq 0
assert_contains "${wrong_systemd_out}" "does not match Darwin launchd scheduler" \
  "Darwin retry reports wrong-platform systemd ownership"
assert_cmd "Darwin retry does not create launchd beside owned systemd files" \
  test ! -e "${scheduler_home}/Library/LaunchAgents/com.vibeguard.gc.plist"
assert_cmd "Darwin retry preserves systemd files and receipt byte-for-byte" bash -c \
  'test "$(shasum -a 256 "$1" "$2" "$3")" = "$4"' _ \
  "${scheduler_service}" "${scheduler_timer}" \
  "${scheduler_home}/.vibeguard/scheduler-ownership" "${wrong_systemd_before}"

printf 'Environment="CUSTOM_FLAG=preserve"\n' >> "${scheduler_service}"
sed -e 's/OnCalendar=.*/OnCalendar=Mon *-*-* 04:30:00/' \
  "${scheduler_timer}" > "${scheduler_timer}.custom"
mv "${scheduler_timer}.custom" "${scheduler_timer}"
custom_scheduler_before="$(
  shasum -a 256 "${scheduler_service}" "${scheduler_timer}"
)"
custom_scheduler_rc=0
custom_scheduler_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${scheduler_home}" \
    VIBEGUARD_TEST_UNAME=Linux \
    VIBEGUARD_TEST_RELEASE_DIR="${scheduler_release}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes 2>&1
)" || custom_scheduler_rc=$?
assert_cmd "default payload retry preserves drifted scheduler with receipt" \
  test "${custom_scheduler_rc}" -eq 0
assert_contains "${custom_scheduler_out}" "scheduler ownership receipt does not match" \
  "drifted systemd scheduler requires explicit --with-scheduler"
assert_cmd "custom systemd Environment and schedule remain byte-identical" bash -c \
  'test "$(shasum -a 256 "$1" "$2")" = "$3"' _ \
  "${scheduler_service}" "${scheduler_timer}" "${custom_scheduler_before}"
custom_scheduler_clean_rc=0
env "${bootstrap_base_env[@]}" \
  HOME="${scheduler_home}" \
  VIBEGUARD_TEST_UNAME=Linux \
  VIBEGUARD_TEST_RELEASE_DIR="${scheduler_release}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --clean \
  >/dev/null 2>&1 || custom_scheduler_clean_rc=$?
assert_cmd "bootstrap clean fails when scheduler cleanup is explicitly deferred" \
  test "${custom_scheduler_clean_rc}" -ne 0
assert_cmd "deferred scheduler cleanup retains the active verified payload" bash -c \
  'test -L "$1" && test -d "$2" && test "$(readlink "$1")" = "$3"' _ \
  "${scheduler_home}/.vibeguard/dist/current" \
  "${scheduler_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}" \
  "${BOOTSTRAP_VERSION}"

unmanaged_scheduler_home="${TMP_HOME}/bootstrap-unmanaged-scheduler-home"
unmanaged_scheduler_dir="${unmanaged_scheduler_home}/.config/systemd/user"
unmanaged_scheduler_service="${unmanaged_scheduler_dir}/vibeguard-gc.service"
unmanaged_scheduler_timer="${unmanaged_scheduler_dir}/vibeguard-gc.timer"
mkdir -p "${unmanaged_scheduler_dir}"
printf '%s\n' '[Service]' 'ExecStart=/usr/local/bin/custom-gc' \
  > "${unmanaged_scheduler_service}"
printf '%s\n' '[Timer]' 'OnCalendar=daily' > "${unmanaged_scheduler_timer}"
unmanaged_scheduler_before="$(
  shasum -a 256 "${unmanaged_scheduler_service}" "${unmanaged_scheduler_timer}"
)"
unmanaged_scheduler_rc=0
unmanaged_scheduler_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${unmanaged_scheduler_home}" \
    VIBEGUARD_TEST_UNAME=Linux \
    VIBEGUARD_TEST_RELEASE_DIR="${scheduler_release}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes 2>&1
)" || unmanaged_scheduler_rc=$?
assert_cmd "default payload install with unmanaged scheduler succeeds" \
  test "${unmanaged_scheduler_rc}" -eq 0
assert_contains "${unmanaged_scheduler_out}" "scheduler ownership receipt is missing" \
  "near-managed scheduler without receipt requires explicit --with-scheduler"
assert_cmd "default payload install preserves unmanaged scheduler files byte-for-byte" bash -c \
  'test "$(shasum -a 256 "$1" "$2")" = "$3"' _ \
  "${unmanaged_scheduler_service}" "${unmanaged_scheduler_timer}" \
  "${unmanaged_scheduler_before}"

launchd_scheduler_home="${TMP_HOME}/bootstrap-launchd-scheduler-home"
launchd_scheduler_plist="${launchd_scheduler_home}/Library/LaunchAgents/com.vibeguard.gc.plist"
mkdir -p "${launchd_scheduler_home}"
launchd_scheduler_rc=0
env "${bootstrap_base_env[@]}" \
  HOME="${launchd_scheduler_home}" \
  VIBEGUARD_TEST_UNAME=Darwin \
  VIBEGUARD_TEST_RELEASE_DIR="${scheduler_release}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes --with-scheduler \
  >/dev/null 2>&1 || launchd_scheduler_rc=$?
assert_cmd "payload bootstrap installs opted-in launchd scheduler" \
  test "${launchd_scheduler_rc}" -eq 0
assert_cmd "payload launchd scheduler records exact ownership hash" bash -c \
  'grep -qFx "schema=1" "$1" && grep -qFx "kind=launchd" "$1" && grep -qFx "phase=managed" "$1" && grep -qE "^plist_sha256=[0-9a-f]{64}$" "$1"' _ \
  "${launchd_scheduler_home}/.vibeguard/scheduler-ownership"
wrong_launchd_before="$(
  shasum -a 256 "${launchd_scheduler_plist}" \
    "${launchd_scheduler_home}/.vibeguard/scheduler-ownership"
)"
wrong_launchd_rc=0
wrong_launchd_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${launchd_scheduler_home}" \
    VIBEGUARD_TEST_UNAME=Linux \
    VIBEGUARD_TEST_RELEASE_DIR="${scheduler_release}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes 2>&1
)" || wrong_launchd_rc=$?
assert_cmd "Linux payload retry preserves a Darwin scheduler HOME" \
  test "${wrong_launchd_rc}" -eq 0
assert_contains "${wrong_launchd_out}" "does not match Linux systemd scheduler" \
  "Linux retry reports wrong-platform launchd ownership"
assert_cmd "Linux retry does not create systemd beside owned launchd files" bash -c \
  'test ! -e "$1" && test ! -e "$2"' _ \
  "${launchd_scheduler_home}/.config/systemd/user/vibeguard-gc.service" \
  "${launchd_scheduler_home}/.config/systemd/user/vibeguard-gc.timer"
assert_cmd "Linux retry preserves launchd file and receipt byte-for-byte" bash -c \
  'test "$(shasum -a 256 "$1" "$2")" = "$3"' _ \
  "${launchd_scheduler_plist}" \
  "${launchd_scheduler_home}/.vibeguard/scheduler-ownership" \
  "${wrong_launchd_before}"
python3 - "${launchd_scheduler_plist}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace(
    "        <string>--scheduled</string>",
    "        <string>--scheduled</string>\n        <string>--custom-user-arg</string>",
    1,
)
text = text.replace("<integer>3</integer>", "<integer>5</integer>", 1)
path.write_text(text, encoding="utf-8")
PY
launchd_custom_before="$(shasum -a 256 "${launchd_scheduler_plist}")"
launchd_custom_rc=0
launchd_custom_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${launchd_scheduler_home}" \
    VIBEGUARD_TEST_UNAME=Darwin \
    VIBEGUARD_TEST_RELEASE_DIR="${scheduler_release}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes 2>&1
)" || launchd_custom_rc=$?
assert_cmd "default payload retry preserves drifted launchd scheduler" \
  test "${launchd_custom_rc}" -eq 0
assert_contains "${launchd_custom_out}" "scheduler ownership receipt does not match" \
  "custom launchd args and schedule require explicit --with-scheduler"
assert_cmd "custom launchd args and schedule remain byte-identical" bash -c \
  'test "$(shasum -a 256 "$1")" = "$2"' _ \
  "${launchd_scheduler_plist}" "${launchd_custom_before}"

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
  grep -qFx "nonce=foreign-owner" "${foreign_owner_lock}"

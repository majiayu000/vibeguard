header "runtime install helper contract"

RUNTIME_INSTALL_HELPER="${REPO_DIR}/scripts/setup/runtime-install.sh"
U29_CHECK="${REPO_DIR}/scripts/ci/self-application/check-u29-no-silent-degrade.sh"

make_runtime_install_repo_copy() {
  local dest="$1"
  mkdir -p "${dest}"
  git -C "${REPO_DIR}" archive HEAD | tar -x -C "${dest}"
  cp "${REPO_DIR}/scripts/setup/install.sh" "${dest}/scripts/setup/install.sh"
  if [[ -f "${RUNTIME_INSTALL_HELPER}" ]]; then
    cp "${RUNTIME_INSTALL_HELPER}" "${dest}/scripts/setup/runtime-install.sh"
  fi
}

assert_no_setup_side_effects() {
  local fixture="$1" home="$2" download_log="$3" cargo_log="$4"
  assert_cmd "${fixture} performs no runtime download" test ! -s "${download_log}"
  assert_cmd "${fixture} performs no source build" test ! -s "${cargo_log}"
  assert_cmd "${fixture} does not create ~/.vibeguard" test ! -e "${home}/.vibeguard"
  assert_cmd "${fixture} does not create ~/.claude" test ! -e "${home}/.claude"
  assert_cmd "${fixture} does not create ~/.codex" test ! -e "${home}/.codex"
}

assert_cmd "runtime install helper exists" test -f "${RUNTIME_INSTALL_HELPER}"
assert_cmd "install entrypoint sources runtime helper" grep -qF \
  'source "${SCRIPT_DIR}/runtime-install.sh"' "${REPO_DIR}/scripts/setup/install.sh"
assert_cmd "runtime install helper syntax is correct" bash -n "${RUNTIME_INSTALL_HELPER}"
assert_cmd "install entrypoint stays below U-16 hard limit" bash -c \
  'test "$(wc -l < "$1")" -lt 800' _ "${REPO_DIR}/scripts/setup/install.sh"
assert_cmd "runtime install helper stays below focused limit" bash -c \
  'test "$(wc -l < "$1")" -lt 400' _ "${RUNTIME_INSTALL_HELPER}"

missing_repo="${TMP_HOME}/runtime-helper-missing-repo"
missing_home="${TMP_HOME}/runtime-helper-missing-home"
missing_download_log="${TMP_HOME}/runtime-helper-missing-download.log"
missing_cargo_log="${TMP_HOME}/runtime-helper-missing-cargo.log"
make_runtime_install_repo_copy "${missing_repo}"
rm -f "${missing_repo}/scripts/setup/runtime-install.sh"
mkdir -p "${missing_home}"
: > "${missing_download_log}"
: > "${missing_cargo_log}"
missing_rc=0
missing_out="$(
  HOME="${missing_home}" \
    VIBEGUARD_TEST_DOWNLOAD_LOG="${missing_download_log}" \
    VIBEGUARD_TEST_CARGO_LOG="${missing_cargo_log}" \
    bash "${missing_repo}/setup.sh" --yes 2>&1
)" || missing_rc=$?
assert_cmd "missing runtime helper fails setup" test "${missing_rc}" -ne 0
assert_contains "${missing_out}" "runtime-install.sh" "missing runtime helper identifies source path"
assert_not_contains "${missing_out}" "Setup complete!" "missing runtime helper does not report completion"
assert_no_setup_side_effects "missing runtime helper" "${missing_home}" "${missing_download_log}" "${missing_cargo_log}"

broken_repo="${TMP_HOME}/runtime-helper-broken-repo"
broken_home="${TMP_HOME}/runtime-helper-broken-home"
broken_download_log="${TMP_HOME}/runtime-helper-broken-download.log"
broken_cargo_log="${TMP_HOME}/runtime-helper-broken-cargo.log"
make_runtime_install_repo_copy "${broken_repo}"
printf 'broken_runtime_install() {\n' > "${broken_repo}/scripts/setup/runtime-install.sh"
mkdir -p "${broken_home}"
: > "${broken_download_log}"
: > "${broken_cargo_log}"
broken_rc=0
broken_out="$(
  HOME="${broken_home}" \
    VIBEGUARD_TEST_DOWNLOAD_LOG="${broken_download_log}" \
    VIBEGUARD_TEST_CARGO_LOG="${broken_cargo_log}" \
    bash "${broken_repo}/setup.sh" --yes 2>&1
)" || broken_rc=$?
assert_cmd "broken runtime helper fails setup" test "${broken_rc}" -ne 0
assert_contains "${broken_out}" "syntax error" "broken runtime helper reports syntax error"
assert_not_contains "${broken_out}" "Setup complete!" "broken runtime helper does not report completion"
assert_no_setup_side_effects "broken runtime helper" "${broken_home}" "${broken_download_log}" "${broken_cargo_log}"

header "runtime install fail-closed matrix"

for provenance_mode in optional required; do
  provenance_home="${TMP_HOME}/attestation-failure-${provenance_mode}-home"
  mkdir -p "${provenance_home}"
  provenance_args=(--yes)
  if [[ "${provenance_mode}" == "required" ]]; then
    provenance_args+=(--require-provenance)
  fi
  provenance_rc=0
  provenance_out="$(
    HOME="${provenance_home}" \
      VIBEGUARD_TEST_CARGO_UNAVAILABLE=1 \
      VIBEGUARD_TEST_ATTESTATION_AVAILABLE=1 \
      VIBEGUARD_TEST_GH_AUTH_OK=1 \
      VIBEGUARD_TEST_ATTESTATION_OK=0 \
      bash "${REPO_DIR}/setup.sh" "${provenance_args[@]}" 2>&1
  )" || provenance_rc=$?
  assert_cmd "${provenance_mode} attestation failure exits nonzero" test "${provenance_rc}" -ne 0
  assert_contains "${provenance_out}" "provenance verification failed" "${provenance_mode} attestation failure is visible"
  assert_not_contains "${provenance_out}" "Falling back to source build" "${provenance_mode} attestation failure does not degrade"
  assert_not_contains "${provenance_out}" "Setup complete!" "${provenance_mode} attestation failure does not report completion"
done

unsupported_home="${TMP_HOME}/strict-unsupported-target-home"
mkdir -p "${unsupported_home}"
unsupported_rc=0
unsupported_out="$(
  HOME="${unsupported_home}" \
    VIBEGUARD_TEST_UNAME=Linux \
    VIBEGUARD_TEST_UNAME_M=s390x \
    bash "${REPO_DIR}/setup.sh" --yes --require-provenance 2>&1
)" || unsupported_rc=$?
assert_cmd "strict unsupported target exits nonzero" test "${unsupported_rc}" -ne 0
assert_contains "${unsupported_out}" "requires a supported release target" "strict unsupported target is visible"
assert_not_contains "${unsupported_out}" "Falling back to source build" "strict unsupported target does not degrade"

missing_version_repo="${TMP_HOME}/runtime-version-missing-repo"
missing_version_home="${TMP_HOME}/runtime-version-missing-home"
make_runtime_install_repo_copy "${missing_version_repo}"
rm -f "${missing_version_repo}/vibeguard-runtime/VERSION"
mkdir -p "${missing_version_home}"
missing_version_rc=0
missing_version_out="$(
  HOME="${missing_version_home}" \
    bash "${missing_version_repo}/setup.sh" --yes --require-provenance 2>&1
)" || missing_version_rc=$?
assert_cmd "strict unresolved runtime tag exits nonzero" test "${missing_version_rc}" -ne 0
assert_contains "${missing_version_out}" "requires a resolvable runtime release tag" "strict unresolved runtime tag is visible"
assert_not_contains "${missing_version_out}" "Falling back to source build" "strict unresolved runtime tag does not degrade"

version_fallback_root="${TMP_HOME}/runtime-version-fallback"
version_fallback_log="${version_fallback_root}/fallback.log"
assert_cmd "non-strict runtime version mismatch uses source fallback" env \
  REPO_DIR="${REPO_DIR}" \
  RUNTIME_INSTALL_HELPER="${RUNTIME_INSTALL_HELPER}" \
  VERSION_FALLBACK_ROOT="${version_fallback_root}" \
  VERSION_FALLBACK_LOG="${version_fallback_log}" \
  bash -c '
    set -euo pipefail
    source "${REPO_DIR}/scripts/setup/lib.sh"
    source "${RUNTIME_INSTALL_HELPER}"
    _INSTALL_TMP="${VERSION_FALLBACK_ROOT}/install"
    BUILD_FROM_SOURCE=0
    REQUIRE_PROVENANCE=0
    RUNTIME_VERSION_OVERRIDE=""
    RUNTIME_VERSION_OVERRIDE_SET=0
    download_prebuilt_runtime() {
      local dest="$3"
      mkdir -p "$(dirname "${dest}")"
      printf "#!/usr/bin/env bash\\nprintf \0470.0.0\\n\047\n" > "${dest}"
      chmod +x "${dest}"
    }
    prepare_runtime_from_source() {
      printf "%s\n" "$1" > "${VERSION_FALLBACK_LOG}"
    }
    prepare_runtime_binary
    grep -qF "downloaded runtime does not match repo runtime VERSION" "${VERSION_FALLBACK_LOG}"
  '

header "runtime install U-29 surface"

for poisoned_surface in install helper; do
  fake_repo="${TMP_HOME}/u29-runtime-${poisoned_surface}"
  mkdir -p "${fake_repo}/scripts/setup"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${fake_repo}/scripts/setup/install.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${fake_repo}/scripts/setup/runtime-install.sh"
  if [[ "${poisoned_surface}" == "install" ]]; then
    printf '#!/usr/bin/env bash\necho "using Python fallback"\n' > "${fake_repo}/scripts/setup/install.sh"
  else
    printf '#!/usr/bin/env bash\necho "degraded install without runtime"\n' > "${fake_repo}/scripts/setup/runtime-install.sh"
  fi
  assert_cmd "U-29 rejects ${poisoned_surface}-only runtime degradation" bash -c \
    '! bash "$1" "$2"' _ "${U29_CHECK}" "${fake_repo}"
done

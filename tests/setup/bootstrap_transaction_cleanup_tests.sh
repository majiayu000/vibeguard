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

transaction_temp_home="${TMP_HOME}/bootstrap-transaction-temp-home"
transaction_temp_file="${transaction_temp_home}/.vibeguard/dist/.bootstrap-transaction-write.4321.orphan"
transaction_noncanonical_file="${transaction_temp_home}/.vibeguard/dist/.bootstrap-transaction-not-a-version"
mkdir -p "${transaction_temp_home}"
env "${bootstrap_base_env[@]}" \
  HOME="${transaction_temp_home}" \
  VIBEGUARD_TEST_RELEASE_DIR="${argv_release}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes >/dev/null
printf 'interrupted atomic write\n' > "${transaction_temp_file}"
printf 'unrelated operator evidence\n' > "${transaction_noncanonical_file}"
assert_cmd "bootstrap clean ignores noncanonical records and reaps transaction write temporaries" \
  env "${bootstrap_base_env[@]}" \
  HOME="${transaction_temp_home}" \
  VIBEGUARD_TEST_RELEASE_DIR="${argv_release}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --clean
assert_cmd "transaction temporary cleanup preserves unrelated noncanonical evidence" bash -c \
  'test ! -e "$1" && grep -qFx "unrelated operator evidence" "$2"' _ \
  "${transaction_temp_file}" "${transaction_noncanonical_file}"

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

orphan_work_home="${TMP_HOME}/bootstrap-orphan-work-home"
orphan_work_dir="${orphan_work_home}/.vibeguard/dist/.bootstrap-${BOOTSTRAP_VERSION}.ABC123"
mkdir -p "${orphan_work_dir}"
printf 'stale partial download\n' > "${orphan_work_dir}/partial"
assert_cmd "normal retry reaps canonical orphaned bootstrap work directory" \
  env "${bootstrap_base_env[@]}" \
  HOME="${orphan_work_home}" \
  VIBEGUARD_TEST_RELEASE_DIR="${handoff_release}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes
assert_cmd "normal retry leaves no orphaned bootstrap work directory" \
  test ! -e "${orphan_work_dir}"
orphan_clean_dir="${orphan_work_home}/.vibeguard/dist/.bootstrap-${BOOTSTRAP_VERSION}.XYZ789"
mkdir -p "${orphan_clean_dir}"
assert_cmd "clean retry also reaps canonical orphaned bootstrap work directory" \
  env "${bootstrap_base_env[@]}" \
  HOME="${orphan_work_home}" \
  VIBEGUARD_TEST_RELEASE_DIR="${handoff_release}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --clean
assert_cmd "clean retry removes orphaned work and managed payload" bash -c \
  'test ! -e "$1" && test ! -e "$2" && test ! -L "$3"' _ \
  "${orphan_clean_dir}" \
  "${orphan_work_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}" \
  "${orphan_work_home}/.vibeguard/dist/current"

ambiguous_work_home="${TMP_HOME}/bootstrap-ambiguous-work-home"
ambiguous_work_dir="${ambiguous_work_home}/.vibeguard/dist/.bootstrap-${BOOTSTRAP_VERSION}.bad-nonce"
mkdir -p "${ambiguous_work_dir}"
ambiguous_work_rc=0
env "${bootstrap_base_env[@]}" \
  HOME="${ambiguous_work_home}" \
  VIBEGUARD_TEST_RELEASE_DIR="${handoff_release}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes \
  >/dev/null 2>&1 || ambiguous_work_rc=$?
assert_cmd "ambiguous bootstrap work ownership fails closed" \
  test "${ambiguous_work_rc}" -eq 73
assert_cmd "ambiguous bootstrap work path is preserved for inspection" \
  test -d "${ambiguous_work_dir}"

symlink_work_home="${TMP_HOME}/bootstrap-symlink-work-home"
symlink_work_target="${TMP_HOME}/bootstrap-symlink-work-target"
symlink_work_path="${symlink_work_home}/.vibeguard/dist/.bootstrap-${BOOTSTRAP_VERSION}.DEF456"
mkdir -p "$(dirname "${symlink_work_path}")" "${symlink_work_target}"
ln -s "${symlink_work_target}" "${symlink_work_path}"
symlink_work_rc=0
env "${bootstrap_base_env[@]}" \
  HOME="${symlink_work_home}" \
  VIBEGUARD_TEST_RELEASE_DIR="${handoff_release}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes \
  >/dev/null 2>&1 || symlink_work_rc=$?
assert_cmd "symlink bootstrap work path fails closed" \
  test "${symlink_work_rc}" -eq 73
assert_cmd "symlink bootstrap work path and target are preserved" bash -c \
  'test -L "$1" && test -d "$2"' _ \
  "${symlink_work_path}" "${symlink_work_target}"

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
pregate_release="${TMP_HOME}/bootstrap-release-pregate-counted"
make_hostile_bootstrap_release "${pregate_release}" counted-handoff
pending_lease_home="${TMP_HOME}/bootstrap-pending-lease-crash-home"
pending_lease_bin="${TMP_HOME}/bootstrap-pending-lease-crash-bin"
pending_lease_marker="${TMP_HOME}/bootstrap-pending-lease-crash.marker"
pending_lease_count="${TMP_HOME}/bootstrap-pending-lease-crash.count"
pending_lease_real_ln="$(command -v ln)"
mkdir -p "${pending_lease_home}" "${pending_lease_bin}"
cat > "${pending_lease_bin}/ln" <<SH
#!/usr/bin/env bash
previous="" last=""
for argument in "\$@"; do previous="\${last}"; last="\${argument}"; done
if [[ "\${last}" == */.bootstrap.lock.lease.* \
  && ! -e "${pending_lease_marker}" \
  && -f "\${previous}" ]] \
  && grep -qFx 'state=pending' "\${previous}"; then
  if "${pending_lease_real_ln}" "\$@"; then
    : > "${pending_lease_marker}"
    kill -KILL "\${PPID}"
    exit 137
  fi
  exit 1
fi
exec "${pending_lease_real_ln}" "\$@"
SH
chmod +x "${pending_lease_bin}/ln"
pending_lease_rc=0
env "${bootstrap_base_env[@]}" HOME="${pending_lease_home}" \
  PATH="${pending_lease_bin}:${PATH}" VIBEGUARD_TEST_RELEASE_DIR="${pregate_release}" \
  VIBEGUARD_TEST_SETUP_COUNT="${pending_lease_count}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes \
  >/dev/null 2>&1 || pending_lease_rc=$?
pending_lease_file="$(find "${pending_lease_home}/.vibeguard/dist" -maxdepth 1 \
  -name '.bootstrap.lock.lease.*' -print -quit)"
assert_cmd "SIGKILL before active lease publication leaves pending evidence" bash -c \
  'test "$1" -ne 0 && grep -qFx "state=pending" "$2" && test ! -e "$3"' _ \
  "${pending_lease_rc}" "${pending_lease_file}" "${pending_lease_count}"
assert_cmd "pending lease retry proves setup was gated and recovers" env "${bootstrap_base_env[@]}" \
  HOME="${pending_lease_home}" VIBEGUARD_TEST_RELEASE_DIR="${pregate_release}" \
  VIBEGUARD_TEST_SETUP_COUNT="${pending_lease_count}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes
assert_cmd "pending-window retry executes setup exactly once" \
  bash -c 'test "$(wc -l < "$1")" -eq 1' _ "${pending_lease_count}"
active_lease_home="${TMP_HOME}/bootstrap-active-lease-crash-home"
active_lease_bin="${TMP_HOME}/bootstrap-active-lease-crash-bin"
active_lease_marker="${TMP_HOME}/bootstrap-active-lease-crash.leader"
active_lease_count="${TMP_HOME}/bootstrap-active-lease-crash.count"
active_lease_real_mv="$(command -v mv)"
mkdir -p "${active_lease_home}" "${active_lease_bin}"
cat > "${active_lease_bin}/mv" <<SH
#!/usr/bin/env bash
previous="" last=""
for arg in "\$@"; do previous="\${last}"; last="\${arg}"; done
if [[ "\${last}" == */.bootstrap.lock.lease.* ]] \
  && grep -qFx 'state=active' "\${previous}" 2>/dev/null; then
  if "${active_lease_real_mv}" "\$@"; then
    awk -F= '\$1 == "leader_pid" { print \$2 }' "\${last}" > "${active_lease_marker}"
    kill -KILL "\${PPID}"
    exit 137
  fi
  exit 1
fi
exec "${active_lease_real_mv}" "\$@"
SH
chmod +x "${active_lease_bin}/mv"
active_lease_rc=0
env "${bootstrap_base_env[@]}" HOME="${active_lease_home}" \
  PATH="${active_lease_bin}:${PATH}" VIBEGUARD_TEST_RELEASE_DIR="${pregate_release}" \
  VIBEGUARD_TEST_SETUP_COUNT="${active_lease_count}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes \
  >/dev/null 2>&1 || active_lease_rc=$?
active_lease_leader="$(cat "${active_lease_marker}")"
for _active_lease_attempt in {1..600}; do
  kill -0 "${active_lease_leader}" 2>/dev/null || break
  sleep 0.05
done
active_lease_file="$(find "${active_lease_home}/.vibeguard/dist" -maxdepth 1 \
  -name '.bootstrap.lock.lease.*' -print -quit)"
assert_cmd "SIGKILL after active lease publication preserves identity evidence" bash -c \
  'test "$1" -ne 0 && grep -qFx "state=active" "$2" && test ! -e "$3"' _ \
  "${active_lease_rc}" "${active_lease_file}" "${active_lease_count}"
assert_cmd "active-before-gate retry waits for group death and recovers" env "${bootstrap_base_env[@]}" \
  HOME="${active_lease_home}" VIBEGUARD_TEST_RELEASE_DIR="${pregate_release}" \
  VIBEGUARD_TEST_SETUP_COUNT="${active_lease_count}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes
assert_cmd "active-window retry executes setup exactly once" \
  bash -c 'test "$(wc -l < "$1")" -eq 1' _ "${active_lease_count}"

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

launchd_retry_home="${TMP_HOME}/bootstrap-launchd-refresh-retry-home"
launchd_retry_plist="${launchd_retry_home}/Library/LaunchAgents/com.vibeguard.gc.plist"
launchd_retry_receipt="${launchd_retry_home}/.vibeguard/scheduler-ownership"
launchd_retry_bin="${TMP_HOME}/bootstrap-launchd-refresh-retry-bin"
launchd_retry_marker="${TMP_HOME}/bootstrap-launchd-refresh-retry.marker"
launchd_retry_delegate="$(command -v launchctl)"
mkdir -p "${launchd_retry_home}" "${launchd_retry_bin}"
env "${bootstrap_base_env[@]}" \
  HOME="${launchd_retry_home}" \
  VIBEGUARD_TEST_UNAME=Darwin \
  VIBEGUARD_TEST_RELEASE_DIR="${scheduler_release}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes --with-scheduler \
  >/dev/null
sed -e "s|dist/current/scripts/gc|dist/${BOOTSTRAP_VERSION}/scripts/gc|g" \
  "${launchd_retry_plist}" > "${launchd_retry_plist}.old"
mv "${launchd_retry_plist}.old" "${launchd_retry_plist}"
printf 'schema=1\nkind=launchd\nphase=managed\nplist_sha256=%s\n' \
  "$(shasum -a 256 "${launchd_retry_plist}" | awk '{print $1}')" \
  > "${launchd_retry_receipt}"
printf '%s\n' \
  "${launchd_retry_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}/scripts/gc/gc-scheduled.sh" \
  > "${launchd_retry_home}/.launchctl-vibeguard-target"
launchd_retry_before="$(
  shasum -a 256 "${launchd_retry_plist}" "${launchd_retry_receipt}"
)"
cat > "${launchd_retry_bin}/launchctl" <<SH
#!/usr/bin/env bash
if [[ "\${1:-}" == "bootstrap" && ! -e "${launchd_retry_marker}" ]]; then
  : > "${launchd_retry_marker}"
  exit 78
fi
exec "${launchd_retry_delegate}" "\$@"
SH
chmod +x "${launchd_retry_bin}/launchctl"
launchd_retry_failure_rc=0
env "${bootstrap_base_env[@]}" \
  HOME="${launchd_retry_home}" \
  PATH="${launchd_retry_bin}:${PATH}" \
  VIBEGUARD_TEST_UNAME=Darwin \
  VIBEGUARD_TEST_RELEASE_DIR="${scheduler_release}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes \
  >/dev/null 2>&1 || launchd_retry_failure_rc=$?
assert_cmd "managed launchd refresh failure is visible" \
  test "${launchd_retry_failure_rc}" -ne 0
assert_cmd "failed launchd refresh restores prior plist, receipt, and loaded job" bash -c \
  'test "$(shasum -a 256 "$1" "$2")" = "$3" && test -f "$4"' _ \
  "${launchd_retry_plist}" "${launchd_retry_receipt}" "${launchd_retry_before}" \
  "${launchd_retry_home}/.launchctl-vibeguard-loaded"
launchd_retry_success_rc=0
env "${bootstrap_base_env[@]}" \
  HOME="${launchd_retry_home}" \
  PATH="${launchd_retry_bin}:${PATH}" \
  VIBEGUARD_TEST_UNAME=Darwin \
  VIBEGUARD_TEST_RELEASE_DIR="${scheduler_release}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes \
  >/dev/null 2>&1 || launchd_retry_success_rc=$?
assert_cmd "managed launchd refresh retries successfully after rollback" \
  test "${launchd_retry_success_rc}" -eq 0
assert_cmd "successful retry records stable current scheduler ownership" bash -c \
  'grep -qF "dist/current/scripts/gc/gc-scheduled.sh" "$1" && grep -qFx "phase=managed" "$2"' _ \
  "${launchd_retry_plist}" "${launchd_retry_receipt}"

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

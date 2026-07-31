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
  printf '1 Ss\\n2 S\\n'
  exit 0
fi
printf '1 Ss\\n99999998 S\\n'
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

lease_reuse_root="${TMP_HOME}/bootstrap-lease-reuse"
lease_reuse_file="${lease_reuse_root}/.bootstrap.lock.lease.lease-reuse"
mkdir -p "${lease_reuse_root}"
lease_reuse_pgid="$(ps -p $$ -o pgid= | tr -d '[:space:]')"
printf '%s\n' \
  'schema=1' \
  "owner_pid=$$" \
  'nonce=lease-reuse' \
  'state=active' \
  "leader_pid=$$" \
  "process_group=${lease_reuse_pgid}" \
  'leader_identity=Thu_Jan_1_00:00:00_1970' > "${lease_reuse_file}"
lease_reuse_rc=0
REPO_DIR="${REPO_DIR}" bash -c '
  set -euo pipefail
  source "${REPO_DIR}/scripts/setup/bootstrap-lib.sh"
  source "${REPO_DIR}/scripts/setup/bootstrap_state.sh"
  bootstrap_setup_lease_clear_inactive "$1" "$2" "$3"
' _ "${lease_reuse_file}" "$$" lease-reuse >/dev/null 2>&1 || lease_reuse_rc=$?
assert_cmd "setup lease rejects a live process group with reused leader identity" \
  test "${lease_reuse_rc}" -ne 0
assert_cmd "setup lease PID-reuse ambiguity preserves exact lease evidence" \
  test -f "${lease_reuse_file}"

pending_owner_root="${TMP_HOME}/bootstrap-pending-owner-identity"
pending_owner_lease="${pending_owner_root}/.bootstrap.lock.lease.pending-owner"
mkdir -p "${pending_owner_root}"
printf '%s\n' \
  'schema=2' \
  'owner_pid=77' \
  'owner_identity=Thu_Jan_1_00:00:00_1970' \
  'nonce=pending-owner' \
  'state=pending' > "${pending_owner_lease}"
for legacy_pending_owner_state in zombie reused matching; do
  assert_cmd "schema-2 pending lease stays ambiguous for ${legacy_pending_owner_state} owner" \
    env REPO_DIR="${REPO_DIR}" bash -c '
      set -euo pipefail
      source "${REPO_DIR}/scripts/setup/bootstrap-lib.sh"
      bootstrap_setup_lease_liveness "$1" 77 pending-owner
      test "${BOOTSTRAP_SETUP_LEASE_LIVENESS}" = ambiguous
    ' _ "${pending_owner_lease}"
done

lease_revalidation_root="${TMP_HOME}/bootstrap-lease-revalidation"
lease_revalidation_file="${lease_revalidation_root}/.bootstrap.lock.lease.revalidation"
lease_revalidation_bin="${TMP_HOME}/bootstrap-lease-revalidation-bin"
lease_revalidation_count="${TMP_HOME}/bootstrap-lease-revalidation.count"
lease_revalidation_ready="${TMP_HOME}/bootstrap-lease-revalidation.ready"
lease_revalidation_fifo="${TMP_HOME}/bootstrap-lease-revalidation.fifo"
lease_revalidation_first_out="${TMP_HOME}/bootstrap-lease-revalidation-first.out"
lease_revalidation_second_out="${TMP_HOME}/bootstrap-lease-revalidation-second.out"
lease_revalidation_real_ps="$(command -v ps)"
lease_revalidation_tmp="${lease_revalidation_root}/tmp"
mkdir -p "${lease_revalidation_root}" "${lease_revalidation_bin}" \
  "${lease_revalidation_tmp}"
mkfifo "${lease_revalidation_fifo}"
printf '0\n' > "${lease_revalidation_count}"
printf '%s\n' \
  'schema=1' \
  'owner_pid=99999997' \
  'nonce=revalidation' \
  'state=active' \
  'leader_pid=4242' \
  'process_group=4242' \
  'leader_identity=Thu_Jan_1_00:00:00_1970' > "${lease_revalidation_file}"
cat > "${lease_revalidation_bin}/ps" <<SH
#!/usr/bin/env bash
if [[ "\$*" == "-A -o pid= -o pgid= -o stat=" ]]; then
  count="\$(cat "${lease_revalidation_count}")"
  count="\$((count + 1))"
  printf '%s\n' "\${count}" > "${lease_revalidation_count}"
  if [[ "\${count}" -eq 1 ]]; then
    printf '%s\n' '1 0 Ss'
  elif [[ "\${count}" -eq 2 ]]; then
    : > "${lease_revalidation_ready}"
    IFS= read -r _continue < "${lease_revalidation_fifo}"
    printf '%s\n' '1 0 Ss' '4242 4242 S'
  else
    printf '%s\n' '1 0 Ss' '4242 4242 S'
  fi
elif [[ "\$*" == "-p 4242 -o pid= -o pgid= -o stat= -o lstart=" ]]; then
  printf '%s\n' '4242 4242 S Thu Jan 1 00:00:00 1970'
else
  exec "${lease_revalidation_real_ps}" "\$@"
fi
SH
chmod +x "${lease_revalidation_bin}/ps"
lease_revalidation_first_rc=0
env REPO_DIR="${REPO_DIR}" BOOTSTRAP_TMP="${lease_revalidation_tmp}" \
  PATH="${lease_revalidation_bin}:${PATH}" bash -c '
  set -euo pipefail
  source "${REPO_DIR}/scripts/setup/bootstrap-lib.sh"
  bootstrap_setup_lease_clear_inactive "$1" 99999997 revalidation
' _ "${lease_revalidation_file}" >"${lease_revalidation_first_out}" 2>&1 &
lease_revalidation_first_pid=$!
for _lease_revalidation_attempt in {1..600}; do
  [[ -e "${lease_revalidation_ready}" ]] && break
  sleep 0.05
done
assert_cmd "post-claim liveness pauses after hard-link evidence is established" \
  test -e "${lease_revalidation_ready}"
assert_cmd "canonical setup lease remains visible throughout post-claim validation" bash -c \
  'test -f "$1" && test -n "$(find "$2" -maxdepth 1 -type f -name ".bootstrap.lock.lease.revalidation.evidence.*" -print -quit)"' _ \
  "${lease_revalidation_file}" "${lease_revalidation_root}"
lease_revalidation_second_rc=0
env REPO_DIR="${REPO_DIR}" BOOTSTRAP_TMP="${lease_revalidation_tmp}" \
  PATH="${lease_revalidation_bin}:${PATH}" bash -c '
  set -euo pipefail
  source "${REPO_DIR}/scripts/setup/bootstrap-lib.sh"
  bootstrap_setup_lease_clear_inactive "$1" 99999997 revalidation
' _ "${lease_revalidation_file}" >"${lease_revalidation_second_out}" 2>&1 \
  || lease_revalidation_second_rc=$?
assert_cmd "second recoverer fails closed while canonical lease is revalidated" \
  test "${lease_revalidation_second_rc}" -ne 0
assert_cmd "second recoverer preserves the canonical lease" \
  test -f "${lease_revalidation_file}"
printf 'continue\n' > "${lease_revalidation_fifo}"
wait "${lease_revalidation_first_pid}" || lease_revalidation_first_rc=$?
assert_cmd "first recoverer rejects a group that becomes active during revalidation" \
  test "${lease_revalidation_first_rc}" -ne 0
assert_cmd "failed post-claim revalidation preserves canonical and immutable recovery evidence" bash -c \
  'test -f "$1" && test -n "$(find "$2" -maxdepth 1 -type f -name ".bootstrap.lock.lease.revalidation.evidence.*" -print -quit)" && test -f "${1}.claim"' _ \
  "${lease_revalidation_file}" "${lease_revalidation_root}"

group_state_bin="${TMP_HOME}/bootstrap-group-state-bin"
group_state_real_ps="$(command -v ps)"
mkdir -p "${group_state_bin}"
cat > "${group_state_bin}/ps" <<SH
#!/usr/bin/env bash
case "\${VIBEGUARD_TEST_GROUP_STATE:-}" in
  pgid-zero) printf '%s\n' '1 0 Ss' '4242 4242 S+' ;;
  zombies) printf '%s\n' '1 0 Ss' '4242 4242 Z' '4243 4242 Z+' ;;
  mixed) printf '%s\n' '4242 4242 Z' '4243 4242 S' ;;
  malformed) printf '%s\n' '1 0 Ss' 'broken row' ;;
  *) exec "${group_state_real_ps}" "\$@" ;;
esac
SH
chmod +x "${group_state_bin}/ps"
assert_cmd "unrelated zero PGID does not hide a live setup group" \
  env REPO_DIR="${REPO_DIR}" PATH="${group_state_bin}:${PATH}" \
    VIBEGUARD_TEST_GROUP_STATE=pgid-zero bash -c '
      set -euo pipefail; source "${REPO_DIR}/scripts/setup/bootstrap-lib.sh"
      source "${REPO_DIR}/scripts/setup/bootstrap_state.sh"
      bootstrap_process_group_liveness 4242
      test "${BOOTSTRAP_PROCESS_GROUP_LIVENESS}" = active
    '
assert_cmd "zombie-only setup group is safely classified dead" \
  env REPO_DIR="${REPO_DIR}" PATH="${group_state_bin}:${PATH}" \
    VIBEGUARD_TEST_GROUP_STATE=zombies bash -c '
      set -euo pipefail; source "${REPO_DIR}/scripts/setup/bootstrap-lib.sh"
      source "${REPO_DIR}/scripts/setup/bootstrap_state.sh"
      bootstrap_process_group_liveness 4242
      test "${BOOTSTRAP_PROCESS_GROUP_LIVENESS}" = dead
    '
assert_cmd "live member keeps a mixed zombie setup group active" \
  env REPO_DIR="${REPO_DIR}" PATH="${group_state_bin}:${PATH}" \
    VIBEGUARD_TEST_GROUP_STATE=mixed bash -c '
      set -euo pipefail; source "${REPO_DIR}/scripts/setup/bootstrap-lib.sh"
      source "${REPO_DIR}/scripts/setup/bootstrap_state.sh"
      bootstrap_process_group_liveness 4242
      test "${BOOTSTRAP_PROCESS_GROUP_LIVENESS}" = active
    '
assert_cmd "malformed process-group evidence remains ambiguous" \
  env REPO_DIR="${REPO_DIR}" PATH="${group_state_bin}:${PATH}" \
    VIBEGUARD_TEST_GROUP_STATE=malformed bash -c '
      set -euo pipefail; source "${REPO_DIR}/scripts/setup/bootstrap-lib.sh"
      source "${REPO_DIR}/scripts/setup/bootstrap_state.sh"
      bootstrap_process_group_liveness 4242
      test "${BOOTSTRAP_PROCESS_GROUP_LIVENESS}" = ambiguous
    '
assert_cmd "zero expected process group is rejected as ambiguous" \
  env REPO_DIR="${REPO_DIR}" bash -c '
    set -euo pipefail; source "${REPO_DIR}/scripts/setup/bootstrap-lib.sh"
    source "${REPO_DIR}/scripts/setup/bootstrap_state.sh"
    bootstrap_process_group_liveness 0
    test "${BOOTSTRAP_PROCESS_GROUP_LIVENESS}" = ambiguous
  '

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

legacy_pending_home="${TMP_HOME}/bootstrap-legacy-pending-home"
legacy_pending_root="${legacy_pending_home}/.vibeguard/dist"
legacy_pending_lock="${legacy_pending_root}/.bootstrap.lock"
legacy_pending_nonce="legacy-pending-owner"
legacy_pending_lease="${legacy_pending_root}/.bootstrap.lock.lease.${legacy_pending_nonce}"
legacy_pending_count="${TMP_HOME}/bootstrap-legacy-pending.count"
legacy_pending_release="${TMP_HOME}/bootstrap-release-legacy-pending"
make_hostile_bootstrap_release "${legacy_pending_release}" counted-handoff
mkdir -p "${legacy_pending_root}"
printf 'pid=%s\nnonce=%s\n' "${dead_lock_pid}" "${legacy_pending_nonce}" \
  > "${legacy_pending_lock}"
printf '%s\n' \
  'schema=1' \
  "owner_pid=${dead_lock_pid}" \
  "nonce=${legacy_pending_nonce}" \
  'state=pending' > "${legacy_pending_lease}"
legacy_pending_rc=0
env "${bootstrap_base_env[@]}" \
  HOME="${legacy_pending_home}" \
  VIBEGUARD_TEST_RELEASE_DIR="${legacy_pending_release}" \
  VIBEGUARD_TEST_SETUP_COUNT="${legacy_pending_count}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes \
  >/dev/null 2>&1 || legacy_pending_rc=$?
assert_cmd "schema-1 pending lease without leader evidence fails closed" \
  test "${legacy_pending_rc}" -eq 73
assert_cmd "schema-1 pending ambiguity preserves lock and lease without running setup" bash -c \
  'test -f "$1" && test -f "$2" && test ! -e "$3"' _ \
  "${legacy_pending_lock}" "${legacy_pending_lease}" "${legacy_pending_count}"

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

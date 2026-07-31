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

orphan_setup_home="${TMP_HOME}/bootstrap-orphan-setup-home"
orphan_setup_ready="${TMP_HOME}/bootstrap-orphan-setup.ready"
orphan_setup_fifo="${TMP_HOME}/bootstrap-orphan-setup.fifo"
orphan_setup_first_out="${TMP_HOME}/bootstrap-orphan-setup-first.out"
orphan_setup_retry_out="${TMP_HOME}/bootstrap-orphan-setup-retry.out"
mkdir -p "${orphan_setup_home}"
mkfifo "${orphan_setup_fifo}"
env "${bootstrap_base_env[@]}" \
  HOME="${orphan_setup_home}" \
  VIBEGUARD_TEST_RELEASE_DIR="${lock_wait_release}" \
  VIBEGUARD_TEST_SETUP_READY="${orphan_setup_ready}" \
  VIBEGUARD_TEST_SETUP_CONTINUE_FIFO="${orphan_setup_fifo}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes \
  >"${orphan_setup_first_out}" 2>&1 &
orphan_setup_parent_pid=$!
for _orphan_setup_attempt in {1..100}; do
  [[ -s "${orphan_setup_ready}" ]] && break
  sleep 0.05
done
orphan_setup_pid="$(cat "${orphan_setup_ready}" 2>/dev/null || true)"
assert_cmd "bootstrap publishes the setup child handshake before parent crash" bash -c \
  'test "$1" -gt 1 && kill -0 "$1"' _ "${orphan_setup_pid:-0}"
kill -KILL "${orphan_setup_parent_pid}"
wait "${orphan_setup_parent_pid}" 2>/dev/null || true
assert_cmd "setup child remains active after bootstrap parent SIGKILL" \
  kill -0 "${orphan_setup_pid}"

orphan_setup_retry_rc=0
env "${bootstrap_base_env[@]}" \
  HOME="${orphan_setup_home}" \
  VIBEGUARD_TEST_RELEASE_DIR="${lock_wait_release}" \
  VIBEGUARD_TEST_SETUP_READY="${orphan_setup_ready}" \
  VIBEGUARD_TEST_SETUP_CONTINUE_FIFO="${orphan_setup_fifo}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes \
  >"${orphan_setup_retry_out}" 2>&1 &
orphan_setup_retry_pid=$!
for _orphan_retry_attempt in {1..100}; do
  kill -0 "${orphan_setup_retry_pid}" 2>/dev/null || break
  sleep 0.05
done
if kill -0 "${orphan_setup_retry_pid}" 2>/dev/null; then
  orphan_setup_retry_child="$(cat "${orphan_setup_ready}" 2>/dev/null || true)"
  kill -KILL "${orphan_setup_retry_pid}" 2>/dev/null || true
  wait "${orphan_setup_retry_pid}" 2>/dev/null || true
  kill -TERM "${orphan_setup_retry_child}" 2>/dev/null || true
  orphan_setup_retry_rc=124
else
  wait "${orphan_setup_retry_pid}" || orphan_setup_retry_rc=$?
fi
assert_cmd "retry fails closed while orphaned setup child is active" \
  test "${orphan_setup_retry_rc}" -eq 73
assert_contains "$(cat "${orphan_setup_retry_out}")" "setup process group" \
  "retry identifies the active setup lease"
assert_cmd "active setup retry preserves lock, payload, and transaction" bash -c \
  'test -f "$1" && test -d "$2" && grep -qFx "phase=setup" "$3"' _ \
  "${orphan_setup_home}/.vibeguard/dist/.bootstrap.lock" \
  "${orphan_setup_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}" \
  "${orphan_setup_home}/.vibeguard/dist/.bootstrap-transaction-${BOOTSTRAP_VERSION}"
printf 'continue\n' > "${orphan_setup_fifo}"
for _orphan_child_attempt in {1..100}; do
  kill -0 "${orphan_setup_pid}" 2>/dev/null || break
  sleep 0.05
done
assert_cmd "orphaned setup child finishes without its killed parent" \
  bash -c '! kill -0 "$1" 2>/dev/null' _ "${orphan_setup_pid}"

dual_recovery_home="${TMP_HOME}/bootstrap-dual-recovery-home"
dual_recovery_ready="${TMP_HOME}/bootstrap-dual-recovery.ready"
dual_recovery_setup_fifo="${TMP_HOME}/bootstrap-dual-recovery-setup.fifo"
dual_recovery_ps_fifo="${TMP_HOME}/bootstrap-dual-recovery-ps.fifo"
dual_recovery_ps_ready="${TMP_HOME}/bootstrap-dual-recovery-ps.ready"
dual_recovery_bin="${TMP_HOME}/bootstrap-dual-recovery-bin"
dual_recovery_first_out="${TMP_HOME}/bootstrap-dual-recovery-first.out"
dual_recovery_second_out="${TMP_HOME}/bootstrap-dual-recovery-second.out"
dual_recovery_real_ps="$(command -v ps)"
mkdir -p "${dual_recovery_home}" "${dual_recovery_bin}"
mkfifo "${dual_recovery_setup_fifo}" "${dual_recovery_ps_fifo}"
env "${bootstrap_base_env[@]}" \
  HOME="${dual_recovery_home}" \
  VIBEGUARD_TEST_RELEASE_DIR="${lock_wait_release}" \
  VIBEGUARD_TEST_SETUP_READY="${dual_recovery_ready}" \
  VIBEGUARD_TEST_SETUP_CONTINUE_FIFO="${dual_recovery_setup_fifo}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes \
  >/dev/null 2>&1 &
dual_recovery_parent_pid=$!
for _dual_recovery_setup_attempt in {1..100}; do
  [[ -s "${dual_recovery_ready}" ]] && break
  sleep 0.05
done
dual_recovery_setup_pid="$(cat "${dual_recovery_ready}" 2>/dev/null || true)"
assert_cmd "dual-recovery fixture starts an isolated setup child" bash -c \
  'test "$1" -gt 1 && kill -0 "$1"' _ "${dual_recovery_setup_pid:-0}"
kill -KILL "${dual_recovery_parent_pid}"
wait "${dual_recovery_parent_pid}" 2>/dev/null || true
cat > "${dual_recovery_bin}/ps" <<SH
#!/usr/bin/env bash
if [[ "\$*" == *"pgid="* && ! -e "${dual_recovery_ps_ready}" ]]; then
  : > "${dual_recovery_ps_ready}"
  IFS= read -r _signal < "${dual_recovery_ps_fifo}"
fi
exec "${dual_recovery_real_ps}" "\$@"
SH
chmod +x "${dual_recovery_bin}/ps"
dual_recovery_first_rc=0
env "${bootstrap_base_env[@]}" \
  HOME="${dual_recovery_home}" PATH="${dual_recovery_bin}:${PATH}" \
  VIBEGUARD_TEST_RELEASE_DIR="${lock_wait_release}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes \
  >"${dual_recovery_first_out}" 2>&1 &
dual_recovery_first_pid=$!
for _dual_recovery_pause_attempt in {1..100}; do
  [[ -e "${dual_recovery_ps_ready}" ]] && break
  sleep 0.05
done
assert_cmd "first stale recoverer pauses during setup-group liveness proof" \
  test -e "${dual_recovery_ps_ready}"
dual_recovery_second_rc=0
env "${bootstrap_base_env[@]}" \
  HOME="${dual_recovery_home}" VIBEGUARD_TEST_RELEASE_DIR="${lock_wait_release}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes \
  >"${dual_recovery_second_out}" 2>&1 || dual_recovery_second_rc=$?
assert_cmd "second stale recoverer fails closed while the setup group is active" \
  test "${dual_recovery_second_rc}" -eq 73
assert_contains "$(cat "${dual_recovery_second_out}")" "setup process group" \
  "second stale recoverer observes the canonical active lease"
assert_cmd "dual stale recovery preserves lock, lease, and active setup child" bash -c \
  'test -f "$1" && test -f "$2" && kill -0 "$3"' _ \
  "${dual_recovery_home}/.vibeguard/dist/.bootstrap.lock" \
  "$(find "${dual_recovery_home}/.vibeguard/dist" -maxdepth 1 -name '.bootstrap.lock.lease.*' -print -quit)" \
  "${dual_recovery_setup_pid}"
printf 'continue\n' > "${dual_recovery_ps_fifo}"
wait "${dual_recovery_first_pid}" || dual_recovery_first_rc=$?
assert_cmd "first stale recoverer also fails closed after liveness proof" \
  test "${dual_recovery_first_rc}" -eq 73
printf 'continue\n' > "${dual_recovery_setup_fifo}"
for _dual_recovery_child_attempt in {1..100}; do
  kill -0 "${dual_recovery_setup_pid}" 2>/dev/null || break
  sleep 0.05
done
assert_cmd "dual-recovery orphaned setup child exits after test release" \
  bash -c '! kill -0 "$1" 2>/dev/null' _ "${dual_recovery_setup_pid}"

gate_failure_home="${TMP_HOME}/bootstrap-gate-failure-home"
gate_failure_bin="${TMP_HOME}/bootstrap-gate-failure-bin"
gate_failure_marker="${TMP_HOME}/bootstrap-gate-failure.leader"
gate_failure_real_mv="$(command -v mv)"
mkdir -p "${gate_failure_home}" "${gate_failure_bin}"
cat > "${gate_failure_bin}/mv" <<SH
#!/usr/bin/env bash
previous="" last=""
for arg in "\$@"; do previous="\${last}"; last="\${arg}"; done
if [[ "\${VIBEGUARD_TEST_CLEAR_FAIL:-0}" == "1" \
  && "\${previous}" == */.bootstrap.lock.lease.* && "\${last}" == *.reap.* ]]; then
  exit 73
fi
if [[ "\${last}" == */.bootstrap.lock.lease.* ]] \
  && grep -qFx 'state=active' "\${previous}" 2>/dev/null; then
  "${gate_failure_real_mv}" "\$@"
  awk -F= '\$1 == "leader_pid" { print \$2 }' "\${last}" > "${gate_failure_marker}"
  work_dir="\$(find "${gate_failure_home}/.vibeguard/dist" -maxdepth 1 \
    -type d -name '.bootstrap-*.*' -print -quit)"
  mkdir -p "\${work_dir}/setup-lease-start"
  exit 0
fi
exec "${gate_failure_real_mv}" "\$@"
SH
chmod +x "${gate_failure_bin}/mv"
gate_failure_rc=0
gate_failure_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${gate_failure_home}" \
    PATH="${gate_failure_bin}:${PATH}" \
    VIBEGUARD_TEST_RELEASE_DIR="${handoff_release}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes 2>&1
)" || gate_failure_rc=$?
assert_cmd "setup gate publication failure returns a bounded error" \
  test "${gate_failure_rc}" -ne 0
assert_contains "${gate_failure_out}" "could not publish the setup process-group gate" \
  "setup gate publication failure is visible"
gate_failure_leader="$(cat "${gate_failure_marker}")"
assert_cmd "gate failure terminates and reaps the isolated setup leader" \
  bash -c '! kill -0 "$1" 2>/dev/null' _ "${gate_failure_leader}"
assert_cmd "gate failure releases lock and lease after safe child teardown" bash -c \
  'test ! -e "$1" && test -z "$(find "$2" -maxdepth 1 -name ".bootstrap.lock.lease.*" -print -quit)"' _ \
  "${gate_failure_home}/.vibeguard/dist/.bootstrap.lock" \
  "${gate_failure_home}/.vibeguard/dist"
clear_failure_rc=0
clear_failure_out="$(
  env "${bootstrap_base_env[@]}" HOME="${gate_failure_home}" \
    PATH="${gate_failure_bin}:${PATH}" VIBEGUARD_TEST_CLEAR_FAIL=1 \
    VIBEGUARD_TEST_RELEASE_DIR="${handoff_release}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes 2>&1
)" || clear_failure_rc=$?
assert_cmd "lease-clear failure remains fail-closed after setup leader teardown" \
  test "${clear_failure_rc}" -ne 0
assert_contains "${clear_failure_out}" "active setup lease prevents unsafe bootstrap cleanup" \
  "lease-clear failure is visible during EXIT cleanup"
assert_cmd "lease-clear failure preserves owner lock, lease, and work evidence" bash -c \
  'test -f "$1" && test -n "$(find "$2" -maxdepth 1 -name ".bootstrap.lock.lease.*" -print -quit)" && test -n "$(find "$2" -maxdepth 1 -type d -name ".bootstrap-*.*" -print -quit)"' _ \
  "${gate_failure_home}/.vibeguard/dist/.bootstrap.lock" \
  "${gate_failure_home}/.vibeguard/dist"

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
bootstrap_setup_lease_clear_inactive \
  "${lease_reuse_file}" "$$" lease-reuse >/dev/null 2>&1 || lease_reuse_rc=$?
assert_cmd "setup lease rejects a live process group with reused leader identity" \
  test "${lease_reuse_rc}" -ne 0
assert_cmd "setup lease PID-reuse ambiguity preserves exact lease evidence" \
  test -f "${lease_reuse_file}"

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

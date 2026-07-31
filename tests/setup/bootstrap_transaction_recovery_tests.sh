gate_failure_home="${TMP_HOME}/bootstrap-gate-failure-home"
gate_failure_bin="${TMP_HOME}/bootstrap-gate-failure-bin"
gate_failure_marker="${TMP_HOME}/bootstrap-gate-failure.leader"
gate_failure_real_mv="$(command -v mv)"
gate_failure_real_ln="$(command -v ln)"
mkdir -p "${gate_failure_home}" "${gate_failure_bin}"
cat > "${gate_failure_bin}/mv" <<SH
#!/usr/bin/env bash
previous="" last=""
for arg in "\$@"; do previous="\${last}"; last="\${arg}"; done
if [[ "\${last}" == */.bootstrap.lock.lease.* ]] \
  && grep -qFx 'state=active' "\${previous}" 2>/dev/null; then
  if "${gate_failure_real_mv}" "\$@"; then
    awk -F= '\$1 == "leader_pid" { print \$2 }' "\${last}" > "${gate_failure_marker}"
    work_dir="\$(find "${gate_failure_home}/.vibeguard/dist" -maxdepth 1 \
      -type d -name '.bootstrap-*.*' -print -quit)"
    mkdir -p "\${work_dir}/setup-lease-start"
    exit 0
  fi
  exit 1
fi
exec "${gate_failure_real_mv}" "\$@"
SH
chmod +x "${gate_failure_bin}/mv"
cat > "${gate_failure_bin}/ln" <<SH
#!/usr/bin/env bash
last=""
for arg in "\$@"; do last="\${arg}"; done
if [[ "\${VIBEGUARD_TEST_CLEAR_FAIL:-0}" == "1" \
  && "\${last}" == *.reap.* ]]; then
  exit 73
fi
exec "${gate_failure_real_ln}" "\$@"
SH
chmod +x "${gate_failure_bin}/ln"
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
    test "$*" = "-A -o pid= -o stat=" || return 2
    printf "  1 Ss\n  77 S+\n"
  }
  bootstrap_pid_liveness 77
  test "${BOOTSTRAP_PID_LIVENESS}" = active
' _ "${BOOTSTRAP_LIB}"
assert_cmd "PID classifier treats signal-visible zombies as dead" bash -c '
  source "$1"
  kill() { return 0; }
  ps() {
    test "$*" = "-A -o pid= -o stat=" || return 2
    printf "  1 Ss\n  77 Z+\n"
  }
  bootstrap_pid_liveness 77
  test "${BOOTSTRAP_PID_LIVENESS}" = dead
' _ "${BOOTSTRAP_LIB}"
assert_cmd "PID classifier proves absence from a complete ps table as dead" bash -c '
  source "$1"
  kill() { return 1; }
  ps() {
    test "$*" = "-A -o pid= -o stat=" || return 2
    printf "1 Ss\n77 S\n"
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
      test "$*" = "-A -o pid= -o stat=" || return 2
      case "${table_kind}" in
        empty) printf "" ;;
        header) printf "PID STAT\n1 Ss\n" ;;
        malformed) printf "1 Ss extra\n" ;;
        duplicate) printf "1 Ss\n1 S\n" ;;
      esac
    }
    bootstrap_pid_liveness 99
    test "${BOOTSTRAP_PID_LIVENESS}" = ambiguous
  ' _ "${BOOTSTRAP_LIB}" "${invalid_pid_table}"
done

zombie_lock_home="${TMP_HOME}/bootstrap-zombie-lock-home"
zombie_lock_dir="${zombie_lock_home}/.vibeguard/dist/.bootstrap.lock"
zombie_ready="${TMP_HOME}/bootstrap-zombie-owner.ready"
python3 - "${zombie_ready}" <<'PY' &
import os
from pathlib import Path
import sys
import time

child = os.fork()
if child == 0:
    os._exit(0)
Path(sys.argv[1]).write_text(str(child), encoding="utf-8")
time.sleep(120)
PY
zombie_parent_pid=$!
for _zombie_ready_attempt in {1..100}; do
  [[ -s "${zombie_ready}" ]] && break
  sleep 0.02
done
zombie_owner_pid="$(cat "${zombie_ready}" 2>/dev/null || true)"
for _zombie_state_attempt in {1..100}; do
  [[ "$(ps -p "${zombie_owner_pid:-0}" -o stat= 2>/dev/null)" == Z* ]] && break
  sleep 0.02
done
mkdir -p "$(dirname "${zombie_lock_dir}")"
printf 'pid=%s\nnonce=zombie-owner\n' "${zombie_owner_pid}" > "${zombie_lock_dir}"
zombie_lock_rc=0
env "${bootstrap_base_env[@]}" \
  HOME="${zombie_lock_home}" \
  VIBEGUARD_TEST_RELEASE_DIR="${BOOTSTRAP_RELEASE}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --dry-run --yes \
  >/dev/null 2>&1 || zombie_lock_rc=$?
kill "${zombie_parent_pid}" 2>/dev/null || true
wait "${zombie_parent_pid}" 2>/dev/null || true
assert_cmd "bootstrap recovers a stale lock whose signal-visible owner is zombie" \
  test "${zombie_lock_rc}" -eq 0
assert_cmd "zombie-owner recovery removes the exact stale lock" \
  test ! -e "${zombie_lock_dir}"

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

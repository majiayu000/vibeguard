header "bootstrap bounded setup termination"

assert_cmd "leader-only launch cancellation is queued until its PGID target is published" \
  env REPO_DIR="${REPO_DIR}" bash -c '
    set -euo pipefail
    source "${REPO_DIR}/scripts/setup/bootstrap-lib.sh"
    BOOTSTRAP_SETUP_LAUNCHING=1
    BOOTSTRAP_SETUP_LEADER_PID=4242
    BOOTSTRAP_SETUP_PGID=""
    BOOTSTRAP_SETUP_PENDING_SIGNAL=""
    BOOTSTRAP_SETUP_PENDING_STATUS=""
    bootstrap_cancel_setup TERM 143
    test "${BOOTSTRAP_SETUP_PENDING_SIGNAL}" = TERM
    test "${BOOTSTRAP_SETUP_PENDING_STATUS}" = 143
  '

reaped_cancel_kill_log="${TMP_HOME}/bootstrap-reaped-cancel.kill"
reaped_cancel_rc=0
env REPO_DIR="${REPO_DIR}" REAPED_CANCEL_KILL_LOG="${reaped_cancel_kill_log}" bash -c '
  set -euo pipefail
  source "${REPO_DIR}/scripts/setup/bootstrap-lib.sh"
  BOOTSTRAP_SETUP_LAUNCHING=0
  BOOTSTRAP_SETUP_LEADER_PID=77
  BOOTSTRAP_SETUP_PGID=77
  BOOTSTRAP_SETUP_LEADER_IDENTITY=Thu_Jan_1_00:00:00_1970
  BOOTSTRAP_SETUP_TERMINATION_FAILED=0
  kill() { : > "${REAPED_CANCEL_KILL_LOG}"; return 0; }
  bootstrap_process_identity_liveness() { BOOTSTRAP_PROCESS_IDENTITY_LIVENESS=dead; }
  bootstrap_process_group_liveness() { BOOTSTRAP_PROCESS_GROUP_LIVENESS=dead; }
  bootstrap_cancel_setup TERM 143
' >/dev/null 2>&1 || reaped_cancel_rc=$?
assert_cmd "post-reap cancellation returns conventional status without signaling a reused target" \
  bash -c 'test "$1" -eq 143 && test ! -e "$2"' _ \
  "${reaped_cancel_rc}" "${reaped_cancel_kill_log}"

termination_unit_log="${TMP_HOME}/bootstrap-termination-unit.log"
termination_unit_wait="${TMP_HOME}/bootstrap-termination-unit.wait"
termination_unit_rc=0
env REPO_DIR="${REPO_DIR}" TERMINATION_UNIT_LOG="${termination_unit_log}" \
  TERMINATION_UNIT_WAIT="${termination_unit_wait}" bash -c '
    set -euo pipefail
    source "${REPO_DIR}/scripts/setup/bootstrap-lib.sh"
    BOOTSTRAP_SETUP_TERMINATION_FAILED=0
    kill() { printf "%s\n" "$*" >> "${TERMINATION_UNIT_LOG}"; return 0; }
    wait() { : > "${TERMINATION_UNIT_WAIT}"; return 0; }
    bootstrap_setup_target_ownership() { BOOTSTRAP_SETUP_TARGET_OWNERSHIP=owned; }
    bootstrap_setup_target_wait_inactive() { return 1; }
    bootstrap_setup_group_terminate 4242 4242 darwin-v1:1700000000:000123 TERM
  ' >/dev/null 2>&1 || termination_unit_rc=$?
assert_cmd "unproven KILL escalation returns 73, records failure, and never enters wait" \
  env REPO_DIR="${REPO_DIR}" TERMINATION_UNIT_LOG="${termination_unit_log}" \
    TERMINATION_UNIT_WAIT="${termination_unit_wait}" bash -c '
      set -euo pipefail
      source "${REPO_DIR}/scripts/setup/bootstrap-lib.sh"
      BOOTSTRAP_SETUP_TERMINATION_FAILED=0
      kill() { printf "%s\n" "$*" >> "${TERMINATION_UNIT_LOG}"; return 0; }
      wait() { : > "${TERMINATION_UNIT_WAIT}"; return 0; }
      bootstrap_setup_target_ownership() { BOOTSTRAP_SETUP_TARGET_OWNERSHIP=owned; }
      bootstrap_setup_target_wait_inactive() { return 1; }
      rc=0
      bootstrap_setup_group_terminate \
        4242 4242 darwin-v1:1700000000:000123 TERM >/dev/null 2>&1 || rc=$?
      test "${rc}" -eq 73
      test "${BOOTSTRAP_SETUP_TERMINATION_FAILED}" -eq 1
      test ! -e "${TERMINATION_UNIT_WAIT}"
      grep -qFx -- "-s CONT -- -4242" "${TERMINATION_UNIT_LOG}"
      grep -qFx -- "-s TERM -- -4242" "${TERMINATION_UNIT_LOG}"
      grep -qFx -- "-s KILL -- -4242" "${TERMINATION_UNIT_LOG}"
      ! grep -qE -- "(^| )4242$" "${TERMINATION_UNIT_LOG}"
    '
assert_cmd "unproven termination helper exits with its fail-closed status" \
  test "${termination_unit_rc}" -eq 73

termination_reuse_log="${TMP_HOME}/bootstrap-termination-reuse.log"
assert_cmd "identity change during grace period blocks KILL escalation" \
  env REPO_DIR="${REPO_DIR}" TERMINATION_REUSE_LOG="${termination_reuse_log}" bash -c '
    set -euo pipefail
    source "${REPO_DIR}/scripts/setup/bootstrap-lib.sh"
    ownership_checks=0
    kill() { printf "%s\n" "$*" >> "${TERMINATION_REUSE_LOG}"; return 0; }
    bootstrap_setup_target_wait_inactive() { return 1; }
    bootstrap_setup_target_ownership() {
      ownership_checks=$((ownership_checks + 1))
      [[ "${ownership_checks}" -le 2 ]] \
        && BOOTSTRAP_SETUP_TARGET_OWNERSHIP=owned \
        || BOOTSTRAP_SETUP_TARGET_OWNERSHIP=ambiguous
    }
    rc=0
    bootstrap_setup_group_terminate \
      4242 4242 darwin-v1:1700000000:000123 TERM >/dev/null 2>&1 || rc=$?
    test "${rc}" -eq 73
    grep -qFx -- "-s CONT -- -4242" "${TERMINATION_REUSE_LOG}"
    grep -qFx -- "-s TERM -- -4242" "${TERMINATION_REUSE_LOG}"
    ! grep -q -- "-s KILL" "${TERMINATION_REUSE_LOG}"
  '

termination_cont_reuse_log="${TMP_HOME}/bootstrap-termination-cont-reuse.log"
assert_cmd "identity change after CONT blocks every termination signal" \
  env REPO_DIR="${REPO_DIR}" TERMINATION_CONT_REUSE_LOG="${termination_cont_reuse_log}" \
  bash -c '
    set -euo pipefail
    source "${REPO_DIR}/scripts/setup/bootstrap-lib.sh"
    ownership_checks=0
    kill() { printf "%s\n" "$*" >> "${TERMINATION_CONT_REUSE_LOG}"; return 0; }
    bootstrap_setup_target_ownership() {
      ownership_checks=$((ownership_checks + 1))
      [[ "${ownership_checks}" -eq 1 ]] \
        && BOOTSTRAP_SETUP_TARGET_OWNERSHIP=owned \
        || BOOTSTRAP_SETUP_TARGET_OWNERSHIP=ambiguous
    }
    rc=0
    bootstrap_setup_group_terminate \
      4242 4242 darwin-v1:1700000000:000123 TERM >/dev/null 2>&1 || rc=$?
    test "${rc}" -eq 73
    test "$(wc -l < "${TERMINATION_CONT_REUSE_LOG}")" -eq 1
    grep -qFx -- "-s CONT -- -4242" "${TERMINATION_CONT_REUSE_LOG}"
  '

termination_signal_failure_log="${TMP_HOME}/bootstrap-termination-signal-failure.log"
assert_cmd "group-signal failure never falls back to a reused leader PID" \
  env REPO_DIR="${REPO_DIR}" TERMINATION_SIGNAL_FAILURE_LOG="${termination_signal_failure_log}" \
  bash -c '
    set -euo pipefail
    source "${REPO_DIR}/scripts/setup/bootstrap-lib.sh"
    ownership_checks=0
    kill() {
      printf "%s\n" "$*" >> "${TERMINATION_SIGNAL_FAILURE_LOG}"
      [[ "$*" == "-s TERM -- -4242" ]] && return 1
      return 0
    }
    bootstrap_setup_target_ownership() {
      ownership_checks=$((ownership_checks + 1))
      [[ "${ownership_checks}" -le 2 ]] \
        && BOOTSTRAP_SETUP_TARGET_OWNERSHIP=owned \
        || BOOTSTRAP_SETUP_TARGET_OWNERSHIP=ambiguous
    }
    rc=0
    bootstrap_setup_group_terminate \
      4242 4242 darwin-v1:1700000000:000123 TERM >/dev/null 2>&1 || rc=$?
    test "${rc}" -eq 73
    ! grep -qE -- "(^| )4242$" "${TERMINATION_SIGNAL_FAILURE_LOG}"
  '

unproven_release="${TMP_HOME}/bootstrap-release-unproven-termination"
unproven_home="${TMP_HOME}/bootstrap-unproven-termination-home"
unproven_ready="${TMP_HOME}/bootstrap-unproven-termination.ready"
unproven_ps_marker="${TMP_HOME}/bootstrap-unproven-termination.ps"
unproven_bin="${TMP_HOME}/bootstrap-unproven-termination-bin"
unproven_out="${TMP_HOME}/bootstrap-unproven-termination.out"
unproven_real_ps="$(command -v ps)"
make_hostile_bootstrap_release "${unproven_release}" signal-ignore
mkdir -p "${unproven_home}" "${unproven_bin}"
cat > "${unproven_bin}/ps" <<SH
#!/usr/bin/env bash
if [[ -e "${unproven_ps_marker}" && "\$*" == "-A -o pid= -o pgid= -o stat=" ]]; then
  printf '%s\n' 'malformed process table'
  exit 0
fi
exec "${unproven_real_ps}" "\$@"
SH
chmod +x "${unproven_bin}/ps"
env "${bootstrap_base_env[@]}" HOME="${unproven_home}" \
  PATH="${unproven_bin}:${PATH}" \
  VIBEGUARD_TEST_RELEASE_DIR="${unproven_release}" \
  VIBEGUARD_TEST_SETUP_READY="${unproven_ready}" \
  python3 -c 'import os, signal, sys
for name in ("SIGINT", "SIGTERM", "SIGHUP"):
    signal.signal(getattr(signal, name), signal.SIG_DFL)
os.execvpe("bash", ["bash", *sys.argv[1:]], os.environ)' \
    "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes \
  >"${unproven_out}" 2>&1 &
unproven_parent_pid=$!
for _unproven_ready_attempt in {1..200}; do
  [[ -s "${unproven_ready}" ]] && break
  sleep 0.05
done
read -r unproven_leader_pid unproven_child_pid < "${unproven_ready}"
unproven_pgid="$("${unproven_real_ps}" -p "${unproven_leader_pid}" -o pgid= \
  | tr -d '[:space:]')"
: > "${unproven_ps_marker}"
kill -TERM "${unproven_parent_pid}"
for _unproven_exit_attempt in {1..600}; do
  kill -0 "${unproven_parent_pid}" 2>/dev/null || break
  sleep 0.05
done
unproven_parent_rc=0
if kill -0 "${unproven_parent_pid}" 2>/dev/null; then
  kill -KILL -- "-${unproven_pgid}" 2>/dev/null || true
  kill -KILL "${unproven_parent_pid}" 2>/dev/null || true
  wait "${unproven_parent_pid}" 2>/dev/null || true
  unproven_parent_rc=124
else
  wait "${unproven_parent_pid}" || unproven_parent_rc=$?
fi
assert_cmd "unproven post-KILL liveness exits 73 instead of cleaning evidence" \
  test "${unproven_parent_rc}" -eq 73
assert_contains "$(cat "${unproven_out}")" \
  "setup termination is unproven; preserving lease, lock, payload, and worktree evidence" \
  "termination failure visibly enters the cleanup hard stop"
assert_cmd "termination hard stop preserves lock, lease, payload, and worktree" bash -c '
  test -f "$1"
  test -n "$(find "$2" -maxdepth 1 -type f -name ".bootstrap.lock.lease.*" -print -quit)"
  test -d "$3"
  test -n "$(find "$2" -maxdepth 1 -type d -name ".bootstrap-*.*" -print -quit)"
' _ "${unproven_home}/.vibeguard/dist/.bootstrap.lock" \
  "${unproven_home}/.vibeguard/dist" \
  "${unproven_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}"
kill -KILL -- "-${unproven_pgid}" 2>/dev/null || true
assert_cmd "test cleanup leaves no non-zombie member in the preserved setup group" bash -c '
  for _attempt in {1..100}; do
    if "$1" -A -o pid= -o pgid= -o stat= | awk -v expected="$2" \
      '\''NF == 3 && $2 == expected && $3 !~ /^Z/ { live = 1 } END { exit live }'\''; then
      exit 0
    fi
    sleep 0.02
  done
  exit 1
' _ "${unproven_real_ps}" "${unproven_pgid}"

header "bootstrap stopped setup-group recovery"

for group_fixture in dead all_stopped running mixed malformed; do
  assert_cmd "process-group classifier reports ${group_fixture} fixture safely" \
    env REPO_DIR="${REPO_DIR}" GROUP_FIXTURE="${group_fixture}" bash -c '
      set -euo pipefail
      source "${REPO_DIR}/scripts/setup/bootstrap-lib.sh"
      ps() {
        test "$*" = "-A -o pid= -o pgid= -o stat=" || return 2
        case "${GROUP_FIXTURE}" in
          dead) printf "%s\n" "1 0 Ss" "88 88 Z" ;;
          all_stopped) printf "%s\n" "1 0 Ss" "88 88 T" "89 88 T+" ;;
          running) printf "%s\n" "1 0 Ss" "88 88 S" "89 88 R+" ;;
          mixed) printf "%s\n" "1 0 Ss" "88 88 T" "89 88 S+" ;;
          malformed) printf "%s\n" "1 0 Ss" "bad row" ;;
        esac
      }
      bootstrap_process_group_state 88
      expected_state="${GROUP_FIXTURE}"
      [[ "${GROUP_FIXTURE}" == malformed ]] && expected_state=ambiguous
      test "${BOOTSTRAP_PROCESS_GROUP_STATE}" = "${expected_state}"
    '
done

for unsafe_group_state in running mixed ambiguous; do
  unsafe_signal_marker="${TMP_HOME}/bootstrap-stopped-${unsafe_group_state}.signal"
  assert_cmd "orphan recovery preserves ${unsafe_group_state} setup groups without signaling" \
    env REPO_DIR="${REPO_DIR}" UNSAFE_GROUP_STATE="${unsafe_group_state}" \
      UNSAFE_SIGNAL_MARKER="${unsafe_signal_marker}" bash -c '
      set -euo pipefail
      source "${REPO_DIR}/scripts/setup/bootstrap-lib.sh"
      bootstrap_setup_lease_read() {
        BOOTSTRAP_LEASE_SCHEMA=3 BOOTSTRAP_LEASE_OWNER_PID=77
        BOOTSTRAP_LEASE_NONCE=stopped BOOTSTRAP_LEASE_STATE=active
        BOOTSTRAP_LEASE_OWNER_IDENTITY=darwin-v1:1700000000:000123
        BOOTSTRAP_LEASE_LEADER_PID=88 BOOTSTRAP_LEASE_PGID=88
        BOOTSTRAP_LEASE_LEADER_IDENTITY=darwin-v1:1700000001:000456
      }
      bootstrap_process_identity_liveness() {
        BOOTSTRAP_PROCESS_IDENTITY_LIVENESS=dead
      }
      bootstrap_process_group_state() {
        BOOTSTRAP_PROCESS_GROUP_STATE="${UNSAFE_GROUP_STATE}"
      }
      bootstrap_setup_group_terminate() { : > "${UNSAFE_SIGNAL_MARKER}"; return 0; }
      ! bootstrap_setup_stopped_group_recover ignored 77 stopped
      test ! -e "${UNSAFE_SIGNAL_MARKER}"
    '
done

assert_cmd "orphan recovery rejects a stopped group after leader identity reuse" \
  env REPO_DIR="${REPO_DIR}" \
    REUSED_SIGNAL_MARKER="${TMP_HOME}/bootstrap-stopped-reused.signal" bash -c '
    set -euo pipefail
    source "${REPO_DIR}/scripts/setup/bootstrap-lib.sh"
    bootstrap_setup_lease_read() {
      BOOTSTRAP_LEASE_SCHEMA=3 BOOTSTRAP_LEASE_OWNER_PID=77
      BOOTSTRAP_LEASE_NONCE=stopped BOOTSTRAP_LEASE_STATE=active
      BOOTSTRAP_LEASE_OWNER_IDENTITY=darwin-v1:1700000000:000123
      BOOTSTRAP_LEASE_LEADER_PID=88 BOOTSTRAP_LEASE_PGID=88
      BOOTSTRAP_LEASE_LEADER_IDENTITY=darwin-v1:1700000001:000456
    }
    bootstrap_process_identity_liveness() { BOOTSTRAP_PROCESS_IDENTITY_LIVENESS=dead; }
    bootstrap_process_group_state() { BOOTSTRAP_PROCESS_GROUP_STATE=all_stopped; }
    bootstrap_process_snapshot() {
      BOOTSTRAP_PROCESS_IDENTITY_STRENGTH=strong
      BOOTSTRAP_PROCESS_PGID=88
      BOOTSTRAP_PROCESS_IDENTITY=darwin-v1:1700000001:000999
    }
    bootstrap_setup_group_terminate() { : > "${REUSED_SIGNAL_MARKER}"; return 0; }
    ! bootstrap_setup_stopped_group_recover ignored 77 stopped
    test ! -e "${REUSED_SIGNAL_MARKER}"
  '

stopped_recovery_root="${TMP_HOME}/bootstrap-stopped-recovery"
stopped_recovery_lease="${stopped_recovery_root}/.bootstrap.lock.lease.stopped"
stopped_recovery_tmp="${stopped_recovery_root}/tmp"
mkdir -p "${stopped_recovery_tmp}"
assert_cmd "exact stopped orphan group is terminated and its lease retired" \
  env REPO_DIR="${REPO_DIR}" \
    BOOTSTRAP_TMP="${stopped_recovery_tmp}" \
    STOPPED_RECOVERY_LEASE="${stopped_recovery_lease}" \
    bash -c '
      set -euo pipefail
      source "${REPO_DIR}/scripts/setup/bootstrap-lib.sh"
      set -m
      (trap "" HUP; while :; do sleep 1; done) &
      leader=$!
      bootstrap_process_snapshot "${leader}"
      test "${BOOTSTRAP_PROCESS_IDENTITY_STRENGTH}" = strong
      test "${BOOTSTRAP_PROCESS_PGID}" = "${leader}"
      leader_identity="${BOOTSTRAP_PROCESS_IDENTITY}"
      printf "%s\n" \
        "schema=3" \
        "owner_pid=99999998" \
        "owner_identity=darwin-v1:1:000001" \
        "nonce=stopped" \
        "state=active" \
        "leader_pid=${leader}" \
        "process_group=${leader}" \
        "leader_identity=${leader_identity}" > "${STOPPED_RECOVERY_LEASE}"
      kill -s STOP -- "-${leader}"
      for _attempt in {1..100}; do
        bootstrap_process_group_state "${leader}"
        [[ "${BOOTSTRAP_PROCESS_GROUP_STATE}" == all_stopped ]] && break
        sleep 0.02
      done
      test "${BOOTSTRAP_PROCESS_GROUP_STATE}" = all_stopped
      bootstrap_setup_lease_clear_inactive \
        "${STOPPED_RECOVERY_LEASE}" 99999998 stopped
      test ! -e "${STOPPED_RECOVERY_LEASE}"
      bootstrap_process_group_liveness "${leader}"
      test "${BOOTSTRAP_PROCESS_GROUP_LIVENESS}" = dead
    '

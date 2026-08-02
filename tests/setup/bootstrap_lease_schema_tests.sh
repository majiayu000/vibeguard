header "bootstrap setup lease schema"

schema3_root="${TMP_HOME}/bootstrap-schema3"
schema3_lease="${schema3_root}/.bootstrap.lock.lease.schema3"
schema3_owner_identity="darwin-v1:1700000000:000123"
schema3_leader_identity="darwin-v1:1700000001:000456"
mkdir -p "${schema3_root}"

assert_cmd "schema-3 pending lease round-trips a strong owner identity" bash -c '
  set -euo pipefail
  source "$1"
  bootstrap_setup_lease_write "$2" 77 schema3 pending "$3"
  bootstrap_setup_lease_read "$2"
  test "${BOOTSTRAP_LEASE_SCHEMA}" = 3
  test "${BOOTSTRAP_LEASE_STATE}" = pending
  test "${BOOTSTRAP_LEASE_OWNER_IDENTITY}" = "$3"
' _ "${BOOTSTRAP_LIB}" "${schema3_lease}" "${schema3_owner_identity}"
assert_cmd "schema-3 active lease round-trips strong owner and leader identities" bash -c '
  set -euo pipefail
  source "$1"
  bootstrap_setup_lease_write "$2" 77 schema3 active "$3" 88 88 "$4"
  bootstrap_setup_lease_read "$2"
  test "${BOOTSTRAP_LEASE_SCHEMA}" = 3
  test "${BOOTSTRAP_LEASE_STATE}" = active
  test "${BOOTSTRAP_LEASE_LEADER_PID}" = 88
  test "${BOOTSTRAP_LEASE_PGID}" = 88
  test "${BOOTSTRAP_LEASE_LEADER_IDENTITY}" = "$4"
' _ "${BOOTSTRAP_LIB}" "${schema3_lease}" \
  "${schema3_owner_identity}" "${schema3_leader_identity}"

schema3_pending="${schema3_root}/.bootstrap.lock.lease.pending"
printf '%s\n' \
  'schema=3' \
  'owner_pid=77' \
  "owner_identity=${schema3_owner_identity}" \
  'nonce=pending' \
  'state=pending' > "${schema3_pending}"
assert_cmd "schema-3 pending lease classifies a matching live owner as active" bash -c '
  set -euo pipefail
  source "$1"
  expected_identity="$3"
  bootstrap_pid_liveness() { BOOTSTRAP_PID_LIVENESS=active; }
  bootstrap_process_snapshot() {
    BOOTSTRAP_PROCESS_PGID=77 BOOTSTRAP_PROCESS_STATE=S
    BOOTSTRAP_PROCESS_IDENTITY="${expected_identity}"
    BOOTSTRAP_PROCESS_IDENTITY_STRENGTH=strong
  }
  bootstrap_setup_lease_liveness "$2" 77 pending
  test "${BOOTSTRAP_SETUP_LEASE_LIVENESS}" = active
' _ "${BOOTSTRAP_LIB}" "${schema3_pending}" "${schema3_owner_identity}"
assert_cmd "schema-3 pending lease detects strong owner PID reuse" bash -c '
  set -euo pipefail
  source "$1"
  bootstrap_pid_liveness() { BOOTSTRAP_PID_LIVENESS=active; }
  bootstrap_process_snapshot() {
    BOOTSTRAP_PROCESS_PGID=77 BOOTSTRAP_PROCESS_STATE=S
    BOOTSTRAP_PROCESS_IDENTITY=darwin-v1:1700000000:000999
    BOOTSTRAP_PROCESS_IDENTITY_STRENGTH=strong
  }
  bootstrap_setup_lease_liveness "$2" 77 pending
  test "${BOOTSTRAP_SETUP_LEASE_LIVENESS}" = dead
' _ "${BOOTSTRAP_LIB}" "${schema3_pending}"
assert_cmd "schema-3 pending lease detects a zombie owner" bash -c '
  set -euo pipefail
  source "$1"
  expected_identity="$3"
  bootstrap_pid_liveness() { BOOTSTRAP_PID_LIVENESS=active; }
  bootstrap_process_snapshot() {
    BOOTSTRAP_PROCESS_PGID=77 BOOTSTRAP_PROCESS_STATE=Z
    BOOTSTRAP_PROCESS_IDENTITY="${expected_identity}"
    BOOTSTRAP_PROCESS_IDENTITY_STRENGTH=strong
  }
  bootstrap_setup_lease_liveness "$2" 77 pending
  test "${BOOTSTRAP_SETUP_LEASE_LIVENESS}" = dead
' _ "${BOOTSTRAP_LIB}" "${schema3_pending}" "${schema3_owner_identity}"

legacy_active="${schema3_root}/.bootstrap.lock.lease.legacy-active"
printf '%s\n' \
  'schema=2' \
  'owner_pid=77' \
  'owner_identity=Thu_Jan_1_00:00:00_1970' \
  'nonce=legacy-active' \
  'state=active' \
  'leader_pid=88' \
  'process_group=88' \
  'leader_identity=Thu_Jan_1_00:00:01_1970' > "${legacy_active}"
assert_cmd "live schema-2 active lease remains ambiguous without strong identity" bash -c '
  set -euo pipefail
  source "$1"
  bootstrap_process_group_liveness() { BOOTSTRAP_PROCESS_GROUP_LIVENESS=active; }
  bootstrap_setup_lease_liveness "$2" 77 legacy-active
  test "${BOOTSTRAP_SETUP_LEASE_LIVENESS}" = ambiguous
' _ "${BOOTSTRAP_LIB}" "${legacy_active}"
assert_cmd "dead schema-2 process group remains safely recoverable" bash -c '
  set -euo pipefail
  source "$1"
  bootstrap_process_group_liveness() { BOOTSTRAP_PROCESS_GROUP_LIVENESS=dead; }
  bootstrap_setup_lease_liveness "$2" 77 legacy-active
  test "${BOOTSTRAP_SETUP_LEASE_LIVENESS}" = dead
' _ "${BOOTSTRAP_LIB}" "${legacy_active}"

pending_symlink_root="${TMP_HOME}/bootstrap-pending-publish-symlink"
pending_symlink_lease="${pending_symlink_root}/.bootstrap.lock.lease.pending-race"
pending_symlink_target="${pending_symlink_root}/outside"
pending_symlink_real_ln="$(command -v ln)"
mkdir -p "${pending_symlink_root}/bin" "${pending_symlink_target}"
cat > "${pending_symlink_root}/bin/ln" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
last=""
for argument in "$@"; do last="${argument}"; done
if [[ ! -e "${last}" && ! -L "${last}" ]]; then
  "${PENDING_SYMLINK_REAL_LN:?}" -s "${PENDING_SYMLINK_TARGET:?}" "${last}"
fi
exec "${PENDING_SYMLINK_REAL_LN:?}" "$@"
SH
chmod +x "${pending_symlink_root}/bin/ln"
pending_symlink_rc=0
env REPO_DIR="${REPO_DIR}" PATH="${pending_symlink_root}/bin:${PATH}" \
  PENDING_SYMLINK_TARGET="${pending_symlink_target}" \
  PENDING_SYMLINK_REAL_LN="${pending_symlink_real_ln}" bash -c '
    set -euo pipefail
    source "${REPO_DIR}/scripts/setup/bootstrap-lib.sh"
    bootstrap_setup_lease_write "$1" 77 pending-race pending "$2"
  ' _ "${pending_symlink_lease}" "${schema3_owner_identity}" \
  >/dev/null 2>&1 || pending_symlink_rc=$?
assert_cmd "pending lease destination symlink race fails closed" \
  test "${pending_symlink_rc}" -ne 0
assert_cmd "pending symlink race never moves lease data into the target directory" bash -c '
  test -L "$1"
  test -z "$(find "$2" -mindepth 1 -maxdepth 1 -print -quit)"
' _ "${pending_symlink_lease}" "${pending_symlink_target}"

active_symlink_root="${TMP_HOME}/bootstrap-active-publish-symlink"
active_symlink_lease="${active_symlink_root}/.bootstrap.lock.lease.active-race"
active_symlink_target="${active_symlink_root}/outside"
active_symlink_real_mv="$(command -v mv)"
mkdir -p "${active_symlink_root}/bin" "${active_symlink_target}"
printf '%s\n' \
  'schema=3' \
  'owner_pid=77' \
  "owner_identity=${schema3_owner_identity}" \
  'nonce=active-race' \
  'state=pending' > "${active_symlink_lease}"
cat > "${active_symlink_root}/bin/mv" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
last=""
for argument in "$@"; do last="${argument}"; done
rm -f -- "${last}"
ln -s "${ACTIVE_SYMLINK_TARGET:?}" "${last}"
exec "${ACTIVE_SYMLINK_REAL_MV:?}" "$@"
SH
chmod +x "${active_symlink_root}/bin/mv"
assert_cmd "active lease publish replaces a destination symlink without following it" \
  env REPO_DIR="${REPO_DIR}" PATH="${active_symlink_root}/bin:${PATH}" \
    ACTIVE_SYMLINK_TARGET="${active_symlink_target}" \
    ACTIVE_SYMLINK_REAL_MV="${active_symlink_real_mv}" bash -c '
      set -euo pipefail
      source "${REPO_DIR}/scripts/setup/bootstrap-lib.sh"
      bootstrap_setup_lease_write "$1" 77 active-race active "$2" 88 88 "$3"
      test -f "$1" && test ! -L "$1"
      test -z "$(find "$4" -mindepth 1 -maxdepth 1 -print -quit)"
    ' _ "${active_symlink_lease}" "${schema3_owner_identity}" \
      "${schema3_leader_identity}" "${active_symlink_target}"

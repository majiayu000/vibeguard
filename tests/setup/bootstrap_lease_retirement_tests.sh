header "bootstrap crash-recoverable lease retirement"

# shellcheck source=scripts/setup/bootstrap-lib.sh
source "${BOOTSTRAP_LIB}"

retirement_make_lease() {
  local lease="$1" nonce="$2"
  mkdir -p "${lease%/*}"
  printf '%s\n' \
    'schema=3' \
    'owner_pid=99999998' \
    'owner_identity=darwin-v1:1:000001' \
    "nonce=${nonce}" \
    'state=pending' > "${lease}"
}

retirement_create_dead_claim() {
  local lease="$1" nonce="$2" work="$3"
  mkdir -p "${work}"
  env REPO_DIR="${REPO_DIR}" BOOTSTRAP_TMP="${work}" bash -c '
    set -euo pipefail
    source "${REPO_DIR}/scripts/setup/bootstrap-lib.sh"
    bootstrap_setup_retirement_claim_create "$1" 99999998 "$2"
  ' _ "${lease}" "${nonce}"
}

orphan_candidate_root="${TMP_HOME}/bootstrap-retirement-orphan-candidate"
orphan_candidate_lease="${orphan_candidate_root}/.bootstrap.lock.lease.orphan-candidate"
mkdir -p "${orphan_candidate_root}"
orphan_candidate_path="$({
  env REPO_DIR="${REPO_DIR}" bash -c '
    set -euo pipefail
    source "${REPO_DIR}/scripts/setup/bootstrap-lib.sh"
    bootstrap_process_snapshot $$
    candidate="$1.claim.candidate.$$.${BOOTSTRAP_PROCESS_IDENTITY}.ORPHAN"
    : > "${candidate}"
    printf "%s\n" "${candidate}"
  ' _ "${orphan_candidate_lease}"
})"
retirement_make_lease "${orphan_candidate_lease}" orphan-candidate
assert_cmd "dead pre-claim candidate is cleaned during successful recovery" bash -c '
  set -euo pipefail
  source "$1"
  bootstrap_setup_lease_clear_inactive "$2" 99999998 orphan-candidate
  test ! -e "$3"
' _ "${BOOTSTRAP_LIB}" "${orphan_candidate_lease}" "${orphan_candidate_path}"

retirement_prepare_stage() {
  local root="$1" stage="$2" nonce="$3"
  local lease="${root}/.bootstrap.lock.lease.${nonce}"
  local claim="${lease}.claim" evidence reap
  retirement_make_lease "${lease}" "${nonce}"
  retirement_create_dead_claim "${lease}" "${nonce}" "${root}/work"
  bootstrap_setup_retirement_read "${claim}"
  evidence="${root}/${BOOTSTRAP_RETIRE_EVIDENCE_NAME}"
  reap="${root}/${BOOTSTRAP_RETIRE_REAP_NAME}"
  ln -- "${lease}" "${evidence}"
  [[ "${stage}" == ln_crash ]] && return 0
  bootstrap_setup_retirement_phase_publish \
    "${claim}" "${BOOTSTRAP_RETIRE_CLAIM_NONCE}" evidenced
  bootstrap_setup_retirement_phase_publish \
    "${claim}" "${BOOTSTRAP_RETIRE_CLAIM_NONCE}" retire_intent
  ln -- "${lease}" "${reap}"
  [[ "${stage}" == mv_crash ]] && return 0
  rm -- "${lease}"
  bootstrap_setup_retirement_phase_publish \
    "${claim}" "${BOOTSTRAP_RETIRE_CLAIM_NONCE}" retired
  bootstrap_setup_retirement_phase_publish \
    "${claim}" "${BOOTSTRAP_RETIRE_CLAIM_NONCE}" delete_intent
  case "${stage}" in
    rm_reap_crash) rm -f -- "${reap}" ;;
    rm_evidence_crash) rm -f -- "${evidence}" ;;
  esac
}

for retirement_crash_stage in ln_crash mv_crash rm_reap_crash rm_evidence_crash; do
  retirement_root="${TMP_HOME}/bootstrap-retirement-${retirement_crash_stage}"
  retirement_nonce="retire-${retirement_crash_stage}"
  retirement_lease="${retirement_root}/.bootstrap.lock.lease.${retirement_nonce}"
  retirement_prepare_stage \
    "${retirement_root}" "${retirement_crash_stage}" "${retirement_nonce}"
  assert_cmd "retirement resumes safely after ${retirement_crash_stage}" bash -c '
    set -euo pipefail
    source "$1"
    BOOTSTRAP_TMP="$2/work"
    bootstrap_setup_lease_clear_inactive "$3" 99999998 "$4"
  ' _ "${BOOTSTRAP_LIB}" "${retirement_root}" \
    "${retirement_lease}" "${retirement_nonce}"
  assert_cmd "${retirement_crash_stage} recovery removes lease data and claim metadata" \
    bash -c '
      test ! -e "$1"
      test ! -e "${1}.claim"
      test -z "$(find "$2" -maxdepth 1 \( -name "*.evidence.*" \
        -o -name "*.reap.*" -o -name "*.claim.*" \) -print -quit)"
    ' _ "${retirement_lease}" "${retirement_root}"
done

for retirement_kill_stage in ln_crash mv_crash rm_reap_crash rm_evidence_crash; do
  kill_root="${TMP_HOME}/bootstrap-retirement-kill-${retirement_kill_stage}"
  kill_nonce="kill-${retirement_kill_stage}"
  kill_lease="${kill_root}/.bootstrap.lock.lease.${kill_nonce}"
  kill_bin="${kill_root}/bin"
  mkdir -p "${kill_root}/work" "${kill_bin}"
  retirement_make_lease "${kill_lease}" "${kill_nonce}"
  case "${retirement_kill_stage}" in
    ln_crash) kill_command=ln ;;
    mv_crash) kill_command=ln ;;
    rm_reap_crash|rm_evidence_crash) kill_command=rm ;;
  esac
  real_kill_command="$(command -v "${kill_command}")"
  cat > "${kill_bin}/${kill_command}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
last=""
for argument in "$@"; do last="${argument}"; done
"${REAL_RETIREMENT_TOOL:?}" "$@"
case "${RETIREMENT_KILL_STAGE:?}:${last}" in
  ln_crash:*.evidence.*|mv_crash:*.reap.*|rm_reap_crash:*.reap.*|rm_evidence_crash:*.evidence.*)
    kill -KILL "${PPID}"
    ;;
esac
SH
  chmod +x "${kill_bin}/${kill_command}"
  kill_stage_rc=0
  env REPO_DIR="${REPO_DIR}" BOOTSTRAP_TMP="${kill_root}/work" \
    PATH="${kill_bin}:${PATH}" REAL_RETIREMENT_TOOL="${real_kill_command}" \
    RETIREMENT_KILL_STAGE="${retirement_kill_stage}" bash -c '
      set -euo pipefail
      source "${REPO_DIR}/scripts/setup/bootstrap-lib.sh"
      bootstrap_setup_lease_clear_inactive "$1" 99999998 "$2"
    ' _ "${kill_lease}" "${kill_nonce}" >/dev/null 2>&1 || kill_stage_rc=$?
  assert_cmd "SIGKILL is injected after real ${retirement_kill_stage} filesystem mutation" \
    test "${kill_stage_rc}" -ne 0
  assert_cmd "new process resumes real ${retirement_kill_stage} interruption" bash -c '
    set -euo pipefail
    source "$1"
    BOOTSTRAP_TMP="$2/work"
    bootstrap_setup_lease_clear_inactive "$3" 99999998 "$4"
    test ! -e "$3"
    test ! -e "${3}.claim"
  ' _ "${BOOTSTRAP_LIB}" "${kill_root}" "${kill_lease}" "${kill_nonce}"
done

active_claim_root="${TMP_HOME}/bootstrap-retirement-active-claim"
active_claim_lease="${active_claim_root}/.bootstrap.lock.lease.active-claim"
active_claim_ready="${active_claim_root}/claim.ready"
retirement_make_lease "${active_claim_lease}" active-claim
mkdir -p "${active_claim_root}/work"
env REPO_DIR="${REPO_DIR}" BOOTSTRAP_TMP="${active_claim_root}/work" \
  ACTIVE_CLAIM_READY="${active_claim_ready}" bash -c '
    set -euo pipefail
    source "${REPO_DIR}/scripts/setup/bootstrap-lib.sh"
    bootstrap_setup_retirement_claim_create "$1" 99999998 active-claim
    : > "${ACTIVE_CLAIM_READY}"
    sleep 120
  ' _ "${active_claim_lease}" &
active_claim_pid=$!
for _active_claim_attempt in {1..100}; do
  [[ -e "${active_claim_ready}" ]] && break
  sleep 0.02
done
active_claim_rc=0
BOOTSTRAP_TMP="${active_claim_root}/work" \
  bootstrap_setup_lease_clear_inactive \
    "${active_claim_lease}" 99999998 active-claim >/dev/null 2>&1 || active_claim_rc=$?
kill "${active_claim_pid}" 2>/dev/null || true
wait "${active_claim_pid}" 2>/dev/null || true
assert_cmd "live retirement claimant blocks cooperative takeover" \
  test "${active_claim_rc}" -ne 0
assert_cmd "live claimant rejection preserves lease and fixed claim" bash -c \
  'test -f "$1" && test -f "${1}.claim"' _ "${active_claim_lease}"

for invalid_retirement_kind in symlink extra_marker inode_mismatch phase_gap; do
  invalid_root="${TMP_HOME}/bootstrap-retirement-invalid-${invalid_retirement_kind}"
  invalid_nonce="invalid-${invalid_retirement_kind}"
  invalid_lease="${invalid_root}/.bootstrap.lock.lease.${invalid_nonce}"
  retirement_make_lease "${invalid_lease}" "${invalid_nonce}"
  mkdir -p "${invalid_root}/work"
  case "${invalid_retirement_kind}" in
    symlink)
      ln -s "${invalid_lease}" "${invalid_lease}.evidence.foreign"
      ;;
    extra_marker)
      ln -- "${invalid_lease}" "${invalid_lease}.evidence.one"
      ln -- "${invalid_lease}" "${invalid_lease}.evidence.two"
      ;;
    inode_mismatch)
      retirement_create_dead_claim \
        "${invalid_lease}" "${invalid_nonce}" "${invalid_root}/work"
      cp "${invalid_lease}" "${invalid_lease}.replacement"
      mv -f -- "${invalid_lease}.replacement" "${invalid_lease}"
      ;;
    phase_gap)
      retirement_create_dead_claim \
        "${invalid_lease}" "${invalid_nonce}" "${invalid_root}/work"
      bootstrap_setup_retirement_read "${invalid_lease}.claim"
      bootstrap_setup_retirement_phase_publish \
        "${invalid_lease}.claim" "${BOOTSTRAP_RETIRE_CLAIM_NONCE}" retire_intent
      ;;
  esac
  invalid_retirement_rc=0
  BOOTSTRAP_TMP="${invalid_root}/work" \
    bootstrap_setup_lease_clear_inactive \
      "${invalid_lease}" 99999998 "${invalid_nonce}" \
      >/dev/null 2>&1 || invalid_retirement_rc=$?
  assert_cmd "${invalid_retirement_kind} retirement evidence fails closed" \
    test "${invalid_retirement_rc}" -ne 0
  assert_cmd "${invalid_retirement_kind} failure preserves canonical evidence" \
    test -f "${invalid_lease}"
done

for legacy_topology in linked retired evidence_only; do
  legacy_root="${TMP_HOME}/bootstrap-retirement-legacy-${legacy_topology}"
  legacy_nonce="legacy-${legacy_topology}"
  legacy_lease="${legacy_root}/.bootstrap.lock.lease.${legacy_nonce}"
  legacy_evidence="${legacy_lease}.evidence.111.222"
  legacy_reap="${legacy_lease}.reap.111.333"
  retirement_make_lease "${legacy_lease}" "${legacy_nonce}"
  mkdir -p "${legacy_root}/work"
  ln -- "${legacy_lease}" "${legacy_evidence}"
  if [[ "${legacy_topology}" == retired ]]; then
    mv -- "${legacy_lease}" "${legacy_reap}"
  elif [[ "${legacy_topology}" == evidence_only ]]; then
    rm -- "${legacy_lease}"
  fi
  assert_cmd "complete legacy ${legacy_topology} topology is adopted and retired" bash -c '
    set -euo pipefail
    source "$1"
    BOOTSTRAP_TMP="$2/work"
    bootstrap_setup_lease_clear_inactive "$3" 99999998 "$4"
  ' _ "${BOOTSTRAP_LIB}" "${legacy_root}" "${legacy_lease}" "${legacy_nonce}"
done

retirement_symlink_root="${TMP_HOME}/bootstrap-retirement-reap-symlink-race"
retirement_symlink_lease="${retirement_symlink_root}/.bootstrap.lock.lease.symlink-race"
retirement_symlink_target="${retirement_symlink_root}/outside"
retirement_symlink_real_ln="$(command -v ln)"
retirement_make_lease "${retirement_symlink_lease}" symlink-race
mkdir -p "${retirement_symlink_target}" "${retirement_symlink_root}/bin"
cat > "${retirement_symlink_root}/bin/ln" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
last=""
for argument in "$@"; do last="${argument}"; done
if [[ "${last}" == *.reap.* ]]; then
  if [[ ! -e "${last}" && ! -L "${last}" ]]; then
    "${RETIREMENT_SYMLINK_REAL_LN:?}" -s "${RETIREMENT_SYMLINK_TARGET:?}" "${last}"
  fi
fi
exec "${RETIREMENT_SYMLINK_REAL_LN:?}" "$@"
SH
chmod +x "${retirement_symlink_root}/bin/ln"
retirement_symlink_rc=0
env REPO_DIR="${REPO_DIR}" \
  PATH="${retirement_symlink_root}/bin:${PATH}" \
  RETIREMENT_SYMLINK_TARGET="${retirement_symlink_target}" \
  RETIREMENT_SYMLINK_REAL_LN="${retirement_symlink_real_ln}" \
  bash -c '
    set -euo pipefail
    source "${REPO_DIR}/scripts/setup/bootstrap-lib.sh"
    bootstrap_setup_lease_clear_inactive "$1" 99999998 symlink-race
  ' _ "${retirement_symlink_lease}" >/dev/null 2>&1 || retirement_symlink_rc=$?
assert_cmd "reap destination symlink race fails closed" test "${retirement_symlink_rc}" -ne 0
assert_cmd "reap symlink race preserves canonical lease outside its destination" bash -c '
  test -f "$1"
  test -L "$(find "$2" -maxdepth 1 -name "*.reap.*" -print -quit)"
  test -z "$(find "$3" -mindepth 1 -maxdepth 1 -print -quit)"
' _ "${retirement_symlink_lease}" "${retirement_symlink_root}" \
  "${retirement_symlink_target}"

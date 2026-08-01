#!/usr/bin/env bash
# HOME-scoped setup lifecycle lock.

_VG_SETUP_LOCK_DIR=""
_VG_SETUP_LOCK_OWNER=""

cleanup_install_lifecycle() {
  cleanup_install_temps
  setup_lock_release || true
}

setup_preflight_and_lock() {
  stage_install_snapshot
  disabled_skills >/dev/null || return 1
  setup_lock_acquire || return 1
  trap cleanup_install_lifecycle EXIT
  if ! state_preflight; then
    setup_lock_release || true
    return 1
  fi
}

setup_lock_acquire() {
  local lock_parent="${HOME}/.vibeguard"
  local lock_dir="${lock_parent}/setup.lock"
  local owner_file="${lock_dir}/owner"
  local reclaim_owner_file="${lock_dir}/reclaiming"
  local owner_pid="" owner_nonce="" observed_owner="" current_owner="" line
  local reclaim_pid="" reclaim_nonce="" observed_reclaimer="" current_reclaimer=""

  if [[ -L "${lock_parent}" || (-e "${lock_parent}" && ! -d "${lock_parent}") ]]; then
    red "ERROR: setup lock parent must be a regular directory or absent: ${lock_parent}"
    return 1
  fi
  mkdir -p "${lock_parent}" || return 1
  if [[ -L "${lock_dir}" || (-e "${lock_dir}" && ! -d "${lock_dir}") ]]; then
    red "ERROR: setup lock path must be a directory or absent: ${lock_dir}"
    return 1
  fi

  if ! mkdir "${lock_dir}" 2>/dev/null; then
    if [[ -L "${owner_file}" || ! -f "${owner_file}" ]]; then
      red "ERROR: setup lock is malformed: ${lock_dir}"
      return 1
    fi
    observed_owner="$(cat "${owner_file}")" || return 1
    while IFS= read -r line; do
      case "${line}" in
        pid=*) owner_pid="${line#pid=}" ;;
        nonce=*) owner_nonce="${line#nonce=}" ;;
        *) red "ERROR: setup lock owner metadata is malformed"; return 1 ;;
      esac
    done <<< "${observed_owner}"
    if [[ ! "${owner_pid}" =~ ^[0-9]+$ || -z "${owner_nonce}" ]]; then
      red "ERROR: setup lock owner metadata is incomplete"
      return 1
    fi
    if kill -0 "${owner_pid}" 2>/dev/null; then
      red "ERROR: another VibeGuard setup is active (pid ${owner_pid})"
      return 1
    fi

    # The reclaimer record is atomically hard-linked by the runtime. A dead
    # owner is recoverable; a live or malformed owner fails closed.
    if [[ -e "${reclaim_owner_file}" || -L "${reclaim_owner_file}" ]]; then
      if [[ -L "${reclaim_owner_file}" || ! -f "${reclaim_owner_file}" ]]; then
        red "ERROR: setup lock reclaimer metadata is malformed"
        return 1
      fi
      observed_reclaimer="$(cat "${reclaim_owner_file}")" || return 1
      while IFS= read -r line; do
        case "${line}" in
          pid=*) reclaim_pid="${line#pid=}" ;;
          nonce=*) reclaim_nonce="${line#nonce=}" ;;
          *) red "ERROR: setup lock reclaimer metadata is malformed"; return 1 ;;
        esac
      done <<< "${observed_reclaimer}"
      if [[ ! "${reclaim_pid}" =~ ^[0-9]+$ || -z "${reclaim_nonce}" ]]; then
        red "ERROR: setup lock reclaimer metadata is incomplete"
        return 1
      fi
      if kill -0 "${reclaim_pid}" 2>/dev/null; then
        red "ERROR: another VibeGuard setup lock reclaim is active (pid ${reclaim_pid})"
        return 1
      fi
      current_reclaimer="$(cat "${reclaim_owner_file}")" || return 1
      if [[ "${current_reclaimer}" != "${observed_reclaimer}" ]] \
        || ! rm -f -- "${reclaim_owner_file}"; then
        red "ERROR: setup lock reclaimer changed during stale recovery"
        return 1
      fi
    fi
    reclaim_nonce="$$-$(date +%s)-${RANDOM:-0}"
    if ! setup_runtime setup-lock-publish-owner \
      "${lock_dir}" "$$" "${reclaim_nonce}" reclaiming; then
      red "ERROR: another VibeGuard setup lock reclaim is active"
      return 1
    fi
    observed_reclaimer="pid=$$
nonce=${reclaim_nonce}"
    if [[ -L "${owner_file}" || ! -f "${owner_file}" ]] \
      || ! current_owner="$(cat "${owner_file}")" \
      || [[ "${current_owner}" != "${observed_owner}" ]]; then
      rm -f -- "${reclaim_owner_file}" 2>/dev/null || true
      red "ERROR: setup lock owner changed while reclaiming; refusing stale deletion"
      return 1
    fi
    if kill -0 "${owner_pid}" 2>/dev/null; then
      rm -f -- "${reclaim_owner_file}" 2>/dev/null || true
      red "ERROR: setup lock owner became active while reclaiming (pid ${owner_pid})"
      return 1
    fi
    if [[ "$(cat "${reclaim_owner_file}")" != "${observed_reclaimer}" ]] \
      || ! rm -f -- "${reclaim_owner_file}" \
      || ! rm -f -- "${owner_file}" \
      || ! rmdir -- "${lock_dir}"; then
      red "ERROR: stale setup lock contains unexpected data: ${lock_dir}"
      return 1
    fi
    mkdir "${lock_dir}" || return 1
    yellow "  Reclaimed stale VibeGuard setup lock (pid ${owner_pid})"
  fi

  local owner_nonce_value="$$-$(date +%s)-${RANDOM:-0}"
  _VG_SETUP_LOCK_DIR="${lock_dir}"
  _VG_SETUP_LOCK_OWNER="pid=$$
nonce=${owner_nonce_value}"
  if ! setup_runtime setup-lock-publish-owner \
    "${lock_dir}" "$$" "${owner_nonce_value}"; then
    if ! rm -f -- "${owner_file}"; then
      red "ERROR: failed to clean partial setup lock owner: ${owner_file}"
    fi
    if ! rmdir -- "${lock_dir}"; then
      red "ERROR: failed to clean setup lock directory after owner publication failure: ${lock_dir}"
    fi
    _VG_SETUP_LOCK_DIR=""
    _VG_SETUP_LOCK_OWNER=""
    return 1
  fi
}

setup_lock_release() {
  local owner_file current_owner
  [[ -n "${_VG_SETUP_LOCK_DIR}" ]] || return 0
  owner_file="${_VG_SETUP_LOCK_DIR}/owner"
  if [[ -L "${owner_file}" || ! -f "${owner_file}" ]]; then
    red "ERROR: refusing to release setup lock with invalid owner file"
    return 1
  fi
  current_owner="$(cat "${owner_file}")" || return 1
  if [[ "${current_owner}" != "${_VG_SETUP_LOCK_OWNER}" ]]; then
    red "ERROR: refusing to release setup lock owned by another process"
    return 1
  fi
  rm -f -- "${owner_file}" || return 1
  rmdir -- "${_VG_SETUP_LOCK_DIR}" || return 1
  _VG_SETUP_LOCK_DIR=""
  _VG_SETUP_LOCK_OWNER=""
}

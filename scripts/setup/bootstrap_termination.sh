#!/usr/bin/env bash
# Bounded setup process-group cancellation and fail-closed escalation.

bootstrap_setup_target_is_inactive() {
  local leader_pid="$1" pgid="$2"
  bootstrap_process_group_liveness "${pgid}"
  [[ "${BOOTSTRAP_PROCESS_GROUP_LIVENESS}" == "dead" ]]
}

bootstrap_setup_target_wait_inactive() {
  local leader_pid="$1" pgid="$2" attempts="$3" attempt
  for ((attempt = 0; attempt < attempts; attempt += 1)); do
    bootstrap_setup_target_is_inactive "${leader_pid}" "${pgid}" && return 0
    sleep 0.05
  done
  return 1
}

bootstrap_setup_target_ownership() {
  local leader_pid="$1" pgid="$2" expected_identity="$3"
  BOOTSTRAP_SETUP_TARGET_OWNERSHIP="ambiguous"
  bootstrap_process_group_liveness "${pgid}"
  if [[ "${BOOTSTRAP_PROCESS_GROUP_LIVENESS}" == "dead" ]]; then
    BOOTSTRAP_SETUP_TARGET_OWNERSHIP="inactive"
    return 0
  fi
  [[ "${BOOTSTRAP_PROCESS_GROUP_LIVENESS}" == "active" ]] || return 0
  bootstrap_process_identity_is_strong "${expected_identity}" || return 0
  bootstrap_process_snapshot "${leader_pid}" || return 0
  if [[ "${BOOTSTRAP_PROCESS_IDENTITY_STRENGTH}" == "strong" \
    && "${BOOTSTRAP_PROCESS_IDENTITY}" == "${expected_identity}" \
    && "${BOOTSTRAP_PROCESS_PGID}" == "${pgid}" ]]; then
    BOOTSTRAP_SETUP_TARGET_OWNERSHIP="owned"
  fi
}

bootstrap_setup_group_terminate() {
  local leader_pid="$1" pgid="$2" expected_identity="$3" initial_signal="${4:-TERM}"
  if [[ ! "${leader_pid}" =~ ^[1-9][0-9]*$ \
    || ! "${pgid}" =~ ^[1-9][0-9]*$ || "${leader_pid}" != "${pgid}" ]] \
    || [[ "${initial_signal}" != "INT" && "${initial_signal}" != "TERM" \
      && "${initial_signal}" != "HUP" ]]; then
    BOOTSTRAP_SETUP_TERMINATION_FAILED=1
    bootstrap_error "refusing to terminate an invalid setup process-group target."
    return 73
  fi
  bootstrap_setup_target_ownership "${leader_pid}" "${pgid}" "${expected_identity}"
  if [[ "${BOOTSTRAP_SETUP_TARGET_OWNERSHIP}" == "inactive" ]]; then
    return 0
  elif [[ "${BOOTSTRAP_SETUP_TARGET_OWNERSHIP}" != "owned" ]]; then
    BOOTSTRAP_SETUP_TERMINATION_FAILED=1
    bootstrap_error "setup process-group ownership is ambiguous; refusing to signal it."
    return 73
  fi
  if ! kill -s CONT -- "-${pgid}" 2>/dev/null; then
    BOOTSTRAP_SETUP_TERMINATION_FAILED=1
    bootstrap_error "could not resume the owned setup process group before termination."
    return 73
  fi
  bootstrap_setup_target_ownership "${leader_pid}" "${pgid}" "${expected_identity}"
  if [[ "${BOOTSTRAP_SETUP_TARGET_OWNERSHIP}" == "inactive" ]]; then
    return 0
  elif [[ "${BOOTSTRAP_SETUP_TARGET_OWNERSHIP}" != "owned" ]]; then
    BOOTSTRAP_SETUP_TERMINATION_FAILED=1
    bootstrap_error "setup process-group ownership changed after CONT; preserving evidence."
    return 73
  fi
  if ! kill -s "${initial_signal}" -- "-${pgid}" 2>/dev/null; then
    bootstrap_setup_target_ownership "${leader_pid}" "${pgid}" "${expected_identity}"
    if [[ "${BOOTSTRAP_SETUP_TARGET_OWNERSHIP}" == "inactive" ]]; then
      return 0
    fi
    BOOTSTRAP_SETUP_TERMINATION_FAILED=1
    bootstrap_error "could not signal the owned setup process group; preserving evidence."
    return 73
  fi
  if ! bootstrap_setup_target_wait_inactive "${leader_pid}" "${pgid}" 40; then
    bootstrap_error "setup process group ignored ${initial_signal}; escalating to KILL."
    bootstrap_setup_target_ownership "${leader_pid}" "${pgid}" "${expected_identity}"
    if [[ "${BOOTSTRAP_SETUP_TARGET_OWNERSHIP}" == "inactive" ]]; then
      return 0
    elif [[ "${BOOTSTRAP_SETUP_TARGET_OWNERSHIP}" != "owned" ]]; then
      BOOTSTRAP_SETUP_TERMINATION_FAILED=1
      bootstrap_error "setup process-group ownership changed before KILL; preserving evidence."
      return 73
    fi
    if ! kill -s KILL -- "-${pgid}" 2>/dev/null; then
      bootstrap_setup_target_ownership "${leader_pid}" "${pgid}" "${expected_identity}"
      if [[ "${BOOTSTRAP_SETUP_TARGET_OWNERSHIP}" == "inactive" ]]; then
        return 0
      fi
      BOOTSTRAP_SETUP_TERMINATION_FAILED=1
      bootstrap_error "could not KILL the owned setup process group; preserving evidence."
      return 73
    fi
    if ! bootstrap_setup_target_wait_inactive "${leader_pid}" "${pgid}" 100; then
      BOOTSTRAP_SETUP_TERMINATION_FAILED=1
      bootstrap_error "could not prove the setup process group terminated after KILL."
      return 73
    fi
  fi
  wait "${leader_pid}" 2>/dev/null || true
  bootstrap_process_group_liveness "${pgid}"
  if [[ "${BOOTSTRAP_PROCESS_GROUP_LIVENESS}" != "dead" ]]; then
    BOOTSTRAP_SETUP_TERMINATION_FAILED=1
    bootstrap_error "setup process group is not proven dead after leader reap."
    return 73
  fi
}

bootstrap_cancel_setup() {
  local signal="$1" status="$2" leader_pid pgid leader_identity
  if [[ "${BOOTSTRAP_SETUP_LAUNCHING:-0}" == "1" ]]; then
    BOOTSTRAP_SETUP_PENDING_SIGNAL="${signal}"
    BOOTSTRAP_SETUP_PENDING_STATUS="${status}"
    return 0
  fi
  trap '' INT TERM HUP
  leader_pid="${BOOTSTRAP_SETUP_LEADER_PID:-}"
  pgid="${BOOTSTRAP_SETUP_PGID:-}"
  leader_identity="${BOOTSTRAP_SETUP_LEADER_IDENTITY:-}"
  if [[ -n "${leader_pid}" || -n "${pgid}" || -n "${leader_identity}" ]]; then
    if [[ -z "${leader_pid}" || -z "${pgid}" || -z "${leader_identity}" ]]; then
      BOOTSTRAP_SETUP_TERMINATION_FAILED=1
      bootstrap_error "setup cancellation target identity is incomplete; preserving ownership evidence."
      exit 73
    fi
    bootstrap_process_identity_liveness "${leader_pid}" "${leader_identity}"
    if [[ "${BOOTSTRAP_PROCESS_IDENTITY_LIVENESS}" == "active" \
      && "${BOOTSTRAP_PROCESS_PGID}" == "${pgid}" ]]; then
      bootstrap_setup_group_terminate \
        "${leader_pid}" "${pgid}" "${leader_identity}" "${signal}" || exit 73
    elif [[ "${BOOTSTRAP_PROCESS_IDENTITY_LIVENESS}" == "dead" ]]; then
      bootstrap_process_group_liveness "${pgid}"
      if [[ "${BOOTSTRAP_PROCESS_GROUP_LIVENESS}" != "dead" ]]; then
        BOOTSTRAP_SETUP_TERMINATION_FAILED=1
        bootstrap_error "setup target identity ended but its process group is not safely attributable."
        exit 73
      fi
    else
      BOOTSTRAP_SETUP_TERMINATION_FAILED=1
      bootstrap_error "setup cancellation target identity is ambiguous; refusing to signal it."
      exit 73
    fi
  fi
  BOOTSTRAP_SETUP_LEADER_PID="" BOOTSTRAP_SETUP_PGID="" BOOTSTRAP_SETUP_LEADER_IDENTITY=""
  exit "${status}"
}

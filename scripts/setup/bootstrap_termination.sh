#!/usr/bin/env bash
# Bounded setup process-group cancellation and fail-closed escalation.

bootstrap_process_group_table_from_proc() {
  local proc_root="$1" stat_file record record_pid rest state pgid
  local table="" had_noglob=0
  [[ -d "${proc_root}" ]] || return 1
  for stat_file in "${proc_root}"/[0-9]*/stat; do
    [[ -e "${stat_file}" ]] || continue
    if ! record="$(<"${stat_file}")"; then
      [[ -e "${stat_file}" ]] && return 1
      continue
    fi
    record_pid="${stat_file%/stat}"
    record_pid="${record_pid##*/}"
    [[ "${record}" == "${record_pid} "* && "${record}" == *") "* ]] || return 1
    rest="${record##*) }"
    [[ $- == *f* ]] && had_noglob=1
    set -f
    # shellcheck disable=SC2086 # Kernel stat fields require intentional word splitting.
    set -- ${rest}
    [[ "${had_noglob}" == "1" ]] || set +f
    [[ $# -ge 3 ]] || return 1
    state="$1" pgid="$3"
    [[ "${state}" =~ ^[A-Za-z]$ && "${pgid}" =~ ^[0-9]+$ ]] || return 1
    table+="${record_pid} ${pgid} ${state}"$'\n'
  done
  [[ -n "${table}" ]] || return 1
  printf '%s' "${table}"
}

bootstrap_process_group_table() {
  local kernel
  kernel="$(command -p uname -s 2>/dev/null)" || return 1
  if [[ "${kernel}" == "Linux" && -r /proc/self/stat ]] \
    && bootstrap_process_group_table_from_proc /proc; then
    return 0
  fi
  LC_ALL=C ps -A -o pid= -o pgid= -o stat= 2>/dev/null
}

bootstrap_process_group_state() {
  local expected_pgid="$1" table state
  BOOTSTRAP_PROCESS_GROUP_STATE="ambiguous"
  [[ "${expected_pgid}" =~ ^[1-9][0-9]*$ ]] || return 0
  table="$(bootstrap_process_group_table)" || return 0
  if state="$(awk -v expected="${expected_pgid}" '
    NF != 3 || $1 !~ /^[1-9][0-9]*$/ || $2 !~ /^[0-9]+$/ { bad = 1; next }
    seen[$1]++ { bad = 1 }
    $2 == expected && $3 !~ /^Z/ {
      live += 1
      if ($3 ~ /^T/) stopped += 1
      else running += 1
    }
    { count += 1 }
    END {
      if (bad || count == 0) exit 1
      if (live == 0) print "dead"
      else if (stopped == live) print "all_stopped"
      else if (running == live) print "running"
      else print "mixed"
    }
  ' <<< "${table}")"; then
    BOOTSTRAP_PROCESS_GROUP_STATE="${state}"
  fi
}

bootstrap_process_group_liveness() {
  local expected_pgid="$1"
  BOOTSTRAP_PROCESS_GROUP_LIVENESS="ambiguous"
  bootstrap_process_group_state "${expected_pgid}"
  case "${BOOTSTRAP_PROCESS_GROUP_STATE}" in
    dead) BOOTSTRAP_PROCESS_GROUP_LIVENESS="dead" ;;
    all_stopped|running|mixed) BOOTSTRAP_PROCESS_GROUP_LIVENESS="active" ;;
  esac
}

bootstrap_setup_job_is_stopped() {
  local pgid="$1"
  bootstrap_process_group_state "${pgid}"
  [[ "${BOOTSTRAP_PROCESS_GROUP_STATE}" == "all_stopped" ]]
}

bootstrap_setup_job_is_active() {
  local child_pid="$1" active_jobs
  active_jobs="$(jobs -p 2>/dev/null)" || return 1
  grep -qFx -- "${child_pid}" <<< "${active_jobs}"
}

bootstrap_setup_gate_wait() {
  local gate_file="$1" owner_pid="$2" owner_identity="$3" max_attempts="$4" attempt
  for ((attempt = 0; attempt < max_attempts; attempt += 1)); do
    [[ -f "${gate_file}" ]] && return 0
    bootstrap_process_identity_liveness "${owner_pid}" "${owner_identity}"
    [[ "${BOOTSTRAP_PROCESS_IDENTITY_LIVENESS}" == active ]] || return 125
    sleep 0.02
  done
  [[ -f "${gate_file}" ]] && return 0
  return 124
}

bootstrap_linux_tty_is_foreground_from_proc_root() {
  local root="$1" pid="$2" record rest pgid tpgid had_noglob=0
  [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || return 1
  record="$(<"${root}/${pid}/stat")" || return 1
  [[ "${record}" == "${pid} "* && "${record}" == *") "* ]] || return 1
  rest="${record##*) }"
  [[ $- == *f* ]] && had_noglob=1
  set -f
  # shellcheck disable=SC2086 # Kernel stat fields require intentional word splitting.
  set -- ${rest}
  [[ "${had_noglob}" == "1" ]] || set +f
  [[ $# -ge 6 ]] || return 1
  pgid="$3" tpgid="$6"
  [[ "${pgid}" =~ ^[1-9][0-9]*$ && "${pgid}" == "${tpgid}" ]]
}

bootstrap_setup_tty_is_foreground() {
  local terminal_state kernel
  [[ -t 0 ]] || return 1
  kernel="$(command -p uname -s 2>/dev/null)" || return 1
  if [[ "${kernel}" == "Linux" ]]; then
    bootstrap_linux_tty_is_foreground_from_proc_root /proc "$$"
    return
  fi
  [[ "${kernel}" == "Darwin" ]] || return 1
  terminal_state="$(LC_ALL=C ps -p $$ -o pgid= -o tpgid= 2>/dev/null)" || return 1
  awk 'NF == 2 && $1 ~ /^[1-9][0-9]*$/ && $1 == $2 { ok = 1 }
       NF != 2 { bad = 1 }
       END { exit !(!bad && ok) }' <<< "${terminal_state}"
}

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

bootstrap_setup_group_resume() {
  local leader_pid="$1" pgid="$2" expected_identity="$3"
  bootstrap_setup_target_ownership "${leader_pid}" "${pgid}" "${expected_identity}"
  if [[ "${BOOTSTRAP_SETUP_TARGET_OWNERSHIP}" != "owned" ]]; then
    BOOTSTRAP_SETUP_TERMINATION_FAILED=1
    bootstrap_error "setup process-group ownership is not proven before CONT."
    return 73
  fi
  if ! kill -s CONT -- "-${pgid}" 2>/dev/null; then
    BOOTSTRAP_SETUP_TERMINATION_FAILED=1
    bootstrap_error "could not resume the owned setup process group."
    return 73
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

bootstrap_setup_cancel_channel_open() {
  local channel="$1" created_inode opened_inode current_inode
  BOOTSTRAP_SETUP_CANCEL_CHANNEL_OPEN=0
  [[ ! -e "${channel}" && ! -L "${channel}" ]] || return 1
  mkfifo -m 600 "${channel}" || return 1
  created_inode="$(bootstrap_file_inode "${channel}")" || {
    rm -f -- "${channel}"; return 1; }
  if ! exec 9<>"${channel}"; then
    rm -f -- "${channel}"
    return 1
  fi
  opened_inode="$(bootstrap_setup_fd_inode 9)" || opened_inode=""
  current_inode="$(bootstrap_file_inode "${channel}")" || current_inode=""
  if [[ -L "${channel}" || ! -p "${channel}" || ! -p /dev/fd/9 \
    || -z "${opened_inode}" || "${opened_inode}" != "${created_inode}" \
    || "${current_inode}" != "${created_inode}" ]]; then
    exec 9>&-
    rm -f -- "${channel}"
    return 1
  fi
  if ! rm -f -- "${channel}"; then
    exec 9>&-
    return 1
  fi
  BOOTSTRAP_SETUP_CANCEL_CHANNEL_OPEN=1
}

bootstrap_setup_fd_inode() {
  local fd="$1" output inode
  output="$(LC_ALL=C ls -Ldi -- "/dev/fd/${fd}" 2>/dev/null)" || return 1
  inode="${output%%[[:space:]]*}"
  [[ "${inode}" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${inode}"
}

bootstrap_setup_cancel_channel_close() {
  [[ "${BOOTSTRAP_SETUP_CANCEL_CHANNEL_OPEN:-0}" == "1" ]] || return 0
  exec 9>&-
  BOOTSTRAP_SETUP_CANCEL_CHANNEL_OPEN=0
}

bootstrap_setup_cancel_channel_read() {
  local expected_leader="$1" expected_pgid="$2" expected_identity="$3"
  local signal status leader identity extra
  BOOTSTRAP_SETUP_SUPERVISOR_STATUS=""
  IFS='|' read -r -t 1 signal status leader identity extra <&9 || return 0
  [[ -z "${extra}" && "${leader}" == "${expected_leader}" \
    && "${expected_leader}" == "${expected_pgid}" \
    && "${identity}" == "${expected_identity}" ]] || return 73
  case "${signal}:${status}" in
    INT:130|TERM:143|HUP:129|TSTP:148) ;;
    *) return 73 ;;
  esac
  bootstrap_setup_target_wait_inactive "${expected_leader}" "${expected_pgid}" 100 \
    || return 73
  bootstrap_process_group_liveness "${expected_pgid}"
  [[ "${BOOTSTRAP_PROCESS_GROUP_LIVENESS}" == "dead" ]] || return 73
  BOOTSTRAP_SETUP_SUPERVISOR_STATUS="${status}"
}

bootstrap_setup_cancel_channel_ready() {
  local expected_leader="$1" expected_identity="$2" kind leader identity extra
  IFS='|' read -r -t 10 kind leader identity extra <&9 || return 73
  [[ "${kind}" == "READY" && -z "${extra}" \
    && "${leader}" == "${expected_leader}" \
    && "${identity}" == "${expected_identity}" ]] || return 73
}

bootstrap_setup_cancel_stopped_supervisor() {
  local leader_pid="$1" pgid="$2" expected_identity="$3" supervisor_rc=0
  bootstrap_setup_group_resume "${leader_pid}" "${pgid}" "${expected_identity}" \
    || return 73
  bootstrap_setup_target_ownership "${leader_pid}" "${pgid}" "${expected_identity}"
  if [[ "${BOOTSTRAP_SETUP_TARGET_OWNERSHIP}" != "owned" ]] \
    || ! kill -s TERM -- "${leader_pid}" 2>/dev/null; then
    BOOTSTRAP_SETUP_TERMINATION_FAILED=1
    bootstrap_error "could not cancel the stopped setup supervisor."
    return 73
  fi
  wait "${leader_pid}" || supervisor_rc=$?
  if [[ "${supervisor_rc}" -eq 0 ]] \
    || ! bootstrap_setup_cancel_channel_read \
      "${leader_pid}" "${pgid}" "${expected_identity}" \
    || [[ "${BOOTSTRAP_SETUP_SUPERVISOR_STATUS:-}" != "143" ]]; then
    BOOTSTRAP_SETUP_TERMINATION_FAILED=1
    bootstrap_error "stopped setup supervisor cancellation is not proven."
    return 73
  fi
}

bootstrap_setup_supervisor_cancel() {
  local signal="$1" status="$2" leader_pid="$3" leader_identity="$4"
  local termination_signal="${signal}"
  [[ "${signal}" == "TSTP" ]] && termination_signal="TERM"
  trap '' INT TERM HUP TSTP
  printf '%s|%s|%s|%s\n' \
    "${signal}" "${status}" "${leader_pid}" "${leader_identity}" >&9 || return 73
  bootstrap_setup_group_terminate \
    "${leader_pid}" "${leader_pid}" "${leader_identity}" "${termination_signal}"
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

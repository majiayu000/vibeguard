#!/usr/bin/env bash
# Process-group and setup-lease helpers for the pinned payload bootstrap.

bootstrap_process_snapshot() {
  local expected_pid="$1"
  BOOTSTRAP_PROCESS_PGID="" BOOTSTRAP_PROCESS_STATE="" BOOTSTRAP_PROCESS_IDENTITY=""
  BOOTSTRAP_PROCESS_IDENTITY_STRENGTH="ambiguous"
  bootstrap_strong_process_snapshot "${expected_pid}"
}

bootstrap_process_identity_liveness() {
  local expected_pid="$1" expected_identity="$2"
  BOOTSTRAP_PROCESS_IDENTITY_LIVENESS="ambiguous"
  bootstrap_pid_liveness "${expected_pid}"
  if [[ "${BOOTSTRAP_PID_LIVENESS}" == "dead" ]]; then
    BOOTSTRAP_PROCESS_IDENTITY_LIVENESS="dead"
    return 0
  fi
  [[ "${BOOTSTRAP_PID_LIVENESS}" == "active" ]] || return 0
  bootstrap_process_identity_is_strong "${expected_identity}" || return 0
  bootstrap_process_snapshot "${expected_pid}" || return 0
  if [[ "${BOOTSTRAP_PROCESS_IDENTITY}" != "${expected_identity}" \
    || "${BOOTSTRAP_PROCESS_STATE}" == Z* ]]; then
    BOOTSTRAP_PROCESS_IDENTITY_LIVENESS="dead"
  else
    BOOTSTRAP_PROCESS_IDENTITY_LIVENESS="active"
  fi
}

bootstrap_process_group_state() {
  local expected_pgid="$1" table state
  BOOTSTRAP_PROCESS_GROUP_STATE="ambiguous"
  [[ "${expected_pgid}" =~ ^[1-9][0-9]*$ ]] || return 0
  table="$(LC_ALL=C ps -A -o pid= -o pgid= -o stat= 2>/dev/null)" || return 0
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

bootstrap_setup_lease_read() {
  local lease_file="$1" parsed
  [[ ! -L "${lease_file}" && -f "${lease_file}" ]] || {
    bootstrap_error "setup lease must be a regular file: ${lease_file}"; return 1; }
  parsed="$(awk -F= '
    NR == 1 && $1 == "schema" && ($2 == "1" || $2 == "2" || $2 == "3") { schema = $2; next }
    NR == 2 && $1 == "owner_pid" && $2 ~ /^[1-9][0-9]*$/ { owner = $2; next }
    schema == 1 && NR == 3 && $1 == "nonce" && $2 ~ /^[A-Za-z0-9._-]+$/ { nonce = $2; next }
    schema == 1 && NR == 4 && $1 == "state" && ($2 == "pending" || $2 == "active") { state = $2; next }
    schema == 1 && NR == 5 && state == "active" && $1 == "leader_pid" && $2 ~ /^[1-9][0-9]*$/ { leader = $2; next }
    schema == 1 && NR == 6 && state == "active" && $1 == "process_group" && $2 ~ /^[1-9][0-9]*$/ { pgid = $2; next }
    schema == 1 && NR == 7 && state == "active" && $1 == "leader_identity" && $2 ~ /^[A-Za-z0-9_:.-]+$/ { identity = $2; next }
    (schema == 2 || schema == 3) && NR == 3 && $1 == "owner_identity" && $2 ~ /^[A-Za-z0-9_:.-]+$/ { owner_identity = $2; next }
    (schema == 2 || schema == 3) && NR == 4 && $1 == "nonce" && $2 ~ /^[A-Za-z0-9._-]+$/ { nonce = $2; next }
    (schema == 2 || schema == 3) && NR == 5 && $1 == "state" && ($2 == "pending" || $2 == "active") { state = $2; next }
    (schema == 2 || schema == 3) && NR == 6 && state == "active" && $1 == "leader_pid" && $2 ~ /^[1-9][0-9]*$/ { leader = $2; next }
    (schema == 2 || schema == 3) && NR == 7 && state == "active" && $1 == "process_group" && $2 ~ /^[1-9][0-9]*$/ { pgid = $2; next }
    (schema == 2 || schema == 3) && NR == 8 && state == "active" && $1 == "leader_identity" && $2 ~ /^[A-Za-z0-9_:.-]+$/ { identity = $2; next }
    { bad = 1 }
    END {
      valid_v1 = schema == 1 && ((state == "pending" && NR == 4) ||
        (state == "active" && NR == 7 && leader != "" && pgid != "" && identity != ""))
      valid_v2 = schema == 2 && owner_identity != "" && ((state == "pending" && NR == 5) ||
        (state == "active" && NR == 8 && leader != "" && pgid != "" && identity != ""))
      valid_v3 = schema == 3 && owner_identity != "" && ((state == "pending" && NR == 5) ||
        (state == "active" && NR == 8 && leader != "" && pgid != "" && identity != ""))
      if (!bad && owner != "" && nonce != "" && (valid_v1 || valid_v2 || valid_v3)) {
        print schema "|" owner "|" nonce "|" state "|" leader "|" pgid "|" identity "|" owner_identity
      } else exit 1
    }
  ' "${lease_file}")" || {
    bootstrap_error "setup lease metadata is malformed: ${lease_file}"; return 1; }
  IFS='|' read -r BOOTSTRAP_LEASE_SCHEMA BOOTSTRAP_LEASE_OWNER_PID BOOTSTRAP_LEASE_NONCE \
    BOOTSTRAP_LEASE_STATE BOOTSTRAP_LEASE_LEADER_PID BOOTSTRAP_LEASE_PGID \
    BOOTSTRAP_LEASE_LEADER_IDENTITY BOOTSTRAP_LEASE_OWNER_IDENTITY <<< "${parsed}"
}

bootstrap_setup_lease_write() {
  local lease_file="$1" owner_pid="$2" nonce="$3" state="$4"
  local owner_identity="$5" leader_pid="${6:-}" pgid="${7:-}" identity="${8:-}"
  local temporary
  temporary="$(mktemp "${lease_file}.write.XXXXXXXXXXXX")" || return 1
  if [[ "${state}" == "pending" ]]; then
    if [[ -e "${lease_file}" || -L "${lease_file}" ]]; then
      rm -f -- "${temporary}"
      return 1
    fi
    printf 'schema=3\nowner_pid=%s\nowner_identity=%s\nnonce=%s\nstate=pending\n' \
      "${owner_pid}" "${owner_identity}" "${nonce}" > "${temporary}" || {
        rm -f -- "${temporary}"; return 1; }
  elif [[ "${state}" == "active" ]]; then
    if ! bootstrap_setup_lease_read "${lease_file}" \
      || [[ "${BOOTSTRAP_LEASE_SCHEMA}" != "3" \
        || "${BOOTSTRAP_LEASE_OWNER_PID}" != "${owner_pid}" \
        || "${BOOTSTRAP_LEASE_OWNER_IDENTITY}" != "${owner_identity}" \
        || "${BOOTSTRAP_LEASE_NONCE}" != "${nonce}" \
        || "${BOOTSTRAP_LEASE_STATE}" != "pending" ]]; then
      rm -f -- "${temporary}"
      return 1
    fi
    printf 'schema=3\nowner_pid=%s\nowner_identity=%s\nnonce=%s\nstate=active\nleader_pid=%s\nprocess_group=%s\nleader_identity=%s\n' \
      "${owner_pid}" "${owner_identity}" "${nonce}" "${leader_pid}" "${pgid}" "${identity}" \
      > "${temporary}" || { rm -f -- "${temporary}"; return 1; }
  else
    rm -f -- "${temporary}"
    return 1
  fi
  if [[ "${state}" == "pending" ]]; then
    bootstrap_hard_link_no_follow "${temporary}" "${lease_file}" || {
      rm -f -- "${temporary}"; return 1; }
    rm -f -- "${temporary}" || return 1
  elif ! mv -fT -- "${temporary}" "${lease_file}" 2>/dev/null \
    && ! mv -hf -- "${temporary}" "${lease_file}" 2>/dev/null; then
    rm -f -- "${temporary}"
    return 1
  fi
  [[ ! -L "${lease_file}" && -f "${lease_file}" ]] || return 1
  bootstrap_setup_lease_read "${lease_file}" || return 1
  [[ "${BOOTSTRAP_LEASE_SCHEMA}" == "3" \
    && "${BOOTSTRAP_LEASE_OWNER_PID}" == "${owner_pid}" \
    && "${BOOTSTRAP_LEASE_OWNER_IDENTITY}" == "${owner_identity}" \
    && "${BOOTSTRAP_LEASE_NONCE}" == "${nonce}" \
    && "${BOOTSTRAP_LEASE_STATE}" == "${state}" ]] || return 1
  if [[ "${state}" == "active" ]]; then
    [[ "${BOOTSTRAP_LEASE_LEADER_PID}" == "${leader_pid}" \
      && "${BOOTSTRAP_LEASE_PGID}" == "${pgid}" \
      && "${BOOTSTRAP_LEASE_LEADER_IDENTITY}" == "${identity}" ]] || return 1
  fi
}

bootstrap_setup_lease_liveness() {
  local lease_file="$1" owner_pid="$2" nonce="$3"
  BOOTSTRAP_SETUP_LEASE_LIVENESS="ambiguous"
  bootstrap_setup_lease_read "${lease_file}" || return 0
  [[ "${BOOTSTRAP_LEASE_OWNER_PID}" == "${owner_pid}" \
    && "${BOOTSTRAP_LEASE_NONCE}" == "${nonce}" ]] || return 0
  if [[ "${BOOTSTRAP_LEASE_STATE}" == "pending" ]]; then
    if [[ "${BOOTSTRAP_LEASE_SCHEMA}" != "3" ]]; then
      return 0
    fi
    bootstrap_process_identity_liveness "${owner_pid}" "${BOOTSTRAP_LEASE_OWNER_IDENTITY}"
    if [[ "${BOOTSTRAP_PROCESS_IDENTITY_LIVENESS}" == "active" \
      && "${owner_pid}" == "$$" \
      && "${BOOTSTRAP_PROCESS_IDENTITY}" == "${BOOTSTRAP_LEASE_OWNER_IDENTITY}" ]]; then
      BOOTSTRAP_SETUP_LEASE_LIVENESS="dead"
    else
      BOOTSTRAP_SETUP_LEASE_LIVENESS="${BOOTSTRAP_PROCESS_IDENTITY_LIVENESS}"
    fi
    return 0
  fi
  bootstrap_process_group_liveness "${BOOTSTRAP_LEASE_PGID}"
  if [[ "${BOOTSTRAP_PROCESS_GROUP_LIVENESS}" == "dead" ]]; then
    BOOTSTRAP_SETUP_LEASE_LIVENESS="dead"
    return 0
  fi
  if [[ "${BOOTSTRAP_PROCESS_GROUP_LIVENESS}" == "active" ]] \
    && [[ "${BOOTSTRAP_LEASE_SCHEMA}" == "3" ]] \
    && bootstrap_process_identity_is_strong "${BOOTSTRAP_LEASE_LEADER_IDENTITY}" \
    && bootstrap_process_snapshot "${BOOTSTRAP_LEASE_LEADER_PID}" \
    && [[ "${BOOTSTRAP_PROCESS_PGID}" == "${BOOTSTRAP_LEASE_PGID}" ]] \
    && [[ "${BOOTSTRAP_PROCESS_IDENTITY}" == "${BOOTSTRAP_LEASE_LEADER_IDENTITY}" ]]; then
    BOOTSTRAP_SETUP_LEASE_LIVENESS="active"
  fi
}

bootstrap_setup_stopped_group_recover() {
  local lease_file="$1" owner_pid="$2" nonce="$3"
  bootstrap_setup_lease_read "${lease_file}" || return 1
  [[ "${BOOTSTRAP_LEASE_SCHEMA}" == "3" \
    && "${BOOTSTRAP_LEASE_OWNER_PID}" == "${owner_pid}" \
    && "${BOOTSTRAP_LEASE_NONCE}" == "${nonce}" \
    && "${BOOTSTRAP_LEASE_STATE}" == "active" \
    && "${BOOTSTRAP_LEASE_LEADER_PID}" == "${BOOTSTRAP_LEASE_PGID}" ]] || return 1
  bootstrap_process_identity_liveness \
    "${owner_pid}" "${BOOTSTRAP_LEASE_OWNER_IDENTITY}"
  [[ "${BOOTSTRAP_PROCESS_IDENTITY_LIVENESS}" == "dead" ]] || return 1
  bootstrap_process_group_state "${BOOTSTRAP_LEASE_PGID}"
  [[ "${BOOTSTRAP_PROCESS_GROUP_STATE}" == "all_stopped" ]] || return 1
  bootstrap_process_snapshot "${BOOTSTRAP_LEASE_LEADER_PID}" || return 1
  [[ "${BOOTSTRAP_PROCESS_IDENTITY_STRENGTH}" == "strong" \
    && "${BOOTSTRAP_PROCESS_PGID}" == "${BOOTSTRAP_LEASE_PGID}" \
    && "${BOOTSTRAP_PROCESS_IDENTITY}" == "${BOOTSTRAP_LEASE_LEADER_IDENTITY}" ]] \
    || return 1
  bootstrap_setup_group_terminate \
    "${BOOTSTRAP_LEASE_LEADER_PID}" "${BOOTSTRAP_LEASE_PGID}" \
    "${BOOTSTRAP_LEASE_LEADER_IDENTITY}" TERM
}

bootstrap_setup_lease_clear_inactive() {
  bootstrap_setup_lease_retire_inactive "$1" "$2" "$3"
}

bootstrap_setup_job_is_stopped() {
  local leader_pid="$1" stopped_jobs
  stopped_jobs="$(jobs -s -p 2>/dev/null)" || return 1
  grep -qFx -- "${leader_pid}" <<< "${stopped_jobs}"
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

bootstrap_setup_tty_is_foreground() {
  local terminal_state
  [[ -t 0 ]] || return 1
  terminal_state="$(LC_ALL=C ps -p $$ -o pgid= -o tpgid= 2>/dev/null)" || return 1
  awk 'NF == 2 && $1 ~ /^[1-9][0-9]*$/ && $1 == $2 { ok = 1 }
       NF != 2 { bad = 1 }
       END { exit !(!bad && ok) }' <<< "${terminal_state}"
}

bootstrap_run_setup_with_lease() {
  local setup_path="$1" dist_root="$2" owner_pid="$3" nonce="$4"
  shift 4
  local lease_file="${dist_root}/.bootstrap.lock.lease.${nonce}"
  local gate_file="${BOOTSTRAP_TMP}/setup-lease-start" leader_pid setup_rc=0
  local monitor_enabled=0 tty_requested=0 stopped=0 owner_identity termination_signal
  if ! bootstrap_process_snapshot "${owner_pid}" \
    || [[ "${BOOTSTRAP_PROCESS_IDENTITY_STRENGTH}" != "strong" ]] \
    || [[ "${BOOTSTRAP_PROCESS_STATE}" == Z* ]]; then
    bootstrap_error "could not establish bootstrap owner identity before setup launch."
    return 1
  fi
  owner_identity="${BOOTSTRAP_PROCESS_IDENTITY}"
  bootstrap_setup_lease_write "${lease_file}" "${owner_pid}" "${nonce}" pending \
    "${owner_identity}" || return 1
  BOOTSTRAP_SETUP_LEASE_FILE="${lease_file}" BOOTSTRAP_SETUP_LEASE_HELD=1
  [[ $- == *m* ]] && monitor_enabled=1
  [[ -t 0 ]] && tty_requested=1
  set -m
  BOOTSTRAP_SETUP_LAUNCHING=1
  (
    bootstrap_setup_gate_wait "${gate_file}" "${owner_pid}" "${owner_identity}" 500 || exit $?
    exec env PYTHONDONTWRITEBYTECODE=1 bash "${setup_path}" "$@"
  ) &
  leader_pid=$!
  BOOTSTRAP_SETUP_LEADER_PID="${leader_pid}" BOOTSTRAP_SETUP_PGID="${leader_pid}"
  if ! bootstrap_process_snapshot "${leader_pid}" \
    || [[ "${BOOTSTRAP_PROCESS_IDENTITY_STRENGTH}" != "strong" ]] \
    || [[ "${BOOTSTRAP_PROCESS_PGID}" != "${leader_pid}" ]] \
    || [[ "${BOOTSTRAP_PROCESS_STATE}" == Z* ]]; then
    termination_signal="${BOOTSTRAP_SETUP_PENDING_SIGNAL:-TERM}"
    if ! bootstrap_setup_group_terminate "${leader_pid}" "${leader_pid}" \
      "${BOOTSTRAP_SETUP_LEADER_IDENTITY:-}" "${termination_signal}"; then
      [[ "${monitor_enabled}" == "1" ]] || set +m
      return 73
    fi
    [[ "${monitor_enabled}" == "1" ]] || set +m
    BOOTSTRAP_SETUP_LEADER_PID="" BOOTSTRAP_SETUP_PGID="" BOOTSTRAP_SETUP_LAUNCHING=0
    if [[ -n "${BOOTSTRAP_SETUP_PENDING_SIGNAL:-}" ]]; then
      trap '' INT TERM HUP
      exit "${BOOTSTRAP_SETUP_PENDING_STATUS}"
    fi
    bootstrap_error "could not establish an isolated setup process group."
    return 1
  fi
  BOOTSTRAP_SETUP_PGID="${BOOTSTRAP_PROCESS_PGID}" BOOTSTRAP_SETUP_LEADER_IDENTITY="${BOOTSTRAP_PROCESS_IDENTITY}" BOOTSTRAP_SETUP_LAUNCHING=0
  if [[ -n "${BOOTSTRAP_SETUP_PENDING_SIGNAL:-}" ]]; then
    bootstrap_cancel_setup "${BOOTSTRAP_SETUP_PENDING_SIGNAL}" "${BOOTSTRAP_SETUP_PENDING_STATUS}"
  fi
  if ! bootstrap_setup_lease_write "${lease_file}" "${owner_pid}" "${nonce}" active \
      "${owner_identity}" "${leader_pid}" "${BOOTSTRAP_SETUP_PGID}" \
      "${BOOTSTRAP_SETUP_LEADER_IDENTITY}"; then
    bootstrap_error "could not publish the active setup process-group lease."
    if ! bootstrap_setup_group_terminate "${leader_pid}" "${BOOTSTRAP_SETUP_PGID}" \
      "${BOOTSTRAP_SETUP_LEADER_IDENTITY}"; then
      [[ "${monitor_enabled}" == "1" ]] || set +m
      return 73
    fi
    [[ "${monitor_enabled}" == "1" ]] || set +m
    return 1
  fi
  if [[ "${tty_requested}" == "1" ]]; then
    kill -s STOP -- "-${BOOTSTRAP_SETUP_PGID}" 2>/dev/null || true
    for _bootstrap_stop_attempt in {1..100}; do
      if bootstrap_setup_job_is_stopped "${leader_pid}"; then stopped=1; break; fi
      sleep 0.02
    done
    if [[ "${stopped}" != "1" ]]; then
      if ! bootstrap_setup_group_terminate "${leader_pid}" "${BOOTSTRAP_SETUP_PGID}" \
        "${BOOTSTRAP_SETUP_LEADER_IDENTITY}"; then
        [[ "${monitor_enabled}" == "1" ]] || set +m
        return 73
      fi
      [[ "${monitor_enabled}" == "1" ]] || set +m
      bootstrap_error "could not stop the isolated setup process group before publication."
      return 1
    fi
  fi
  if ! : > "${gate_file}"; then
    bootstrap_error "could not publish the setup process-group gate."
    if ! bootstrap_setup_group_terminate "${leader_pid}" "${BOOTSTRAP_SETUP_PGID}" \
      "${BOOTSTRAP_SETUP_LEADER_IDENTITY}"; then
      [[ "${monitor_enabled}" == "1" ]] || set +m
      return 73
    fi
    [[ "${monitor_enabled}" == "1" ]] || set +m
    if bootstrap_setup_lease_clear_inactive "${lease_file}" "${owner_pid}" "${nonce}"; then
      BOOTSTRAP_SETUP_LEASE_HELD=0 BOOTSTRAP_SETUP_LEASE_FILE=""
    fi
    return 1
  fi
  if [[ "${tty_requested}" == "1" ]]; then
    if ! bootstrap_setup_tty_is_foreground; then
      bootstrap_error "bootstrap stdin is a terminal but its process group is not foreground."
      if ! bootstrap_setup_group_terminate "${leader_pid}" "${BOOTSTRAP_SETUP_PGID}" \
        "${BOOTSTRAP_SETUP_LEADER_IDENTITY}"; then
        [[ "${monitor_enabled}" == "1" ]] || set +m
        return 73
      fi
      setup_rc=73
    elif fg %% >/dev/null; then
      setup_rc=0
    else
      setup_rc=$?
    fi
  else
    kill -s CONT -- "-${BOOTSTRAP_SETUP_PGID}" 2>/dev/null || true
    wait "${leader_pid}" || setup_rc=$?
  fi
  BOOTSTRAP_SETUP_LEADER_PID="" BOOTSTRAP_SETUP_PGID="" BOOTSTRAP_SETUP_LEADER_IDENTITY=""
  [[ "${monitor_enabled}" == "1" ]] || set +m
  bootstrap_setup_lease_clear_inactive "${lease_file}" "${owner_pid}" "${nonce}" || return 73
  BOOTSTRAP_SETUP_LEASE_HELD=0 BOOTSTRAP_SETUP_LEASE_FILE=""
  return "${setup_rc}"
}

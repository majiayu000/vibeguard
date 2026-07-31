#!/usr/bin/env bash
# Process-group and setup-lease helpers for the pinned payload bootstrap.

bootstrap_process_snapshot() {
  local expected_pid="$1" snapshot parsed
  BOOTSTRAP_PROCESS_PGID="" BOOTSTRAP_PROCESS_STATE="" BOOTSTRAP_PROCESS_IDENTITY=""
  snapshot="$(LC_ALL=C ps -p "${expected_pid}" -o pid= -o pgid= -o stat= -o lstart= 2>/dev/null)" || return 1
  parsed="$(awk -v expected="${expected_pid}" '
    NF == 8 && $1 == expected && $1 ~ /^[1-9][0-9]*$/ &&
        $2 ~ /^[1-9][0-9]*$/ && $3 ~ /^[A-Za-z<+]+$/ {
      if ($4 !~ /^[A-Z][a-z][a-z]$/ || $5 !~ /^[A-Z][a-z][a-z]$/ ||
          $6 !~ /^[0-9][0-9]?$/ || $7 !~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/ ||
          $8 !~ /^[0-9][0-9][0-9][0-9]$/) bad = 1
      count += 1
      pgid = $2
      state = $3
      identity = $4 "_" $5 "_" $6 "_" $7 "_" $8
      next
    }
    NF { bad = 1 }
    END {
      if (!bad && count == 1) print pgid "\t" state "\t" identity
      else exit 1
    }
  ' <<< "${snapshot}")" || return 1
  IFS=$'\t' read -r BOOTSTRAP_PROCESS_PGID BOOTSTRAP_PROCESS_STATE \
    BOOTSTRAP_PROCESS_IDENTITY <<< "${parsed}"
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
  bootstrap_process_snapshot "${expected_pid}" || return 0
  if [[ "${BOOTSTRAP_PROCESS_STATE}" == Z* \
    || "${BOOTSTRAP_PROCESS_IDENTITY}" != "${expected_identity}" ]]; then
    BOOTSTRAP_PROCESS_IDENTITY_LIVENESS="dead"
  else
    BOOTSTRAP_PROCESS_IDENTITY_LIVENESS="active"
  fi
}

bootstrap_process_group_liveness() {
  local expected_pgid="$1" table state
  BOOTSTRAP_PROCESS_GROUP_LIVENESS="ambiguous"
  [[ "${expected_pgid}" =~ ^[1-9][0-9]*$ ]] || return 0
  table="$(LC_ALL=C ps -A -o pid= -o pgid= -o stat= 2>/dev/null)" || return 0
  if state="$(awk -v expected="${expected_pgid}" '
    NF != 3 || $1 !~ /^[1-9][0-9]*$/ || $2 !~ /^[0-9]+$/ { bad = 1; next }
    seen[$1]++ { bad = 1 }
    $2 == expected && $3 !~ /^Z/ { found = 1 }
    { count += 1 }
    END {
      if (bad || count == 0) exit 1
      print found ? "active" : "dead"
    }
  ' <<< "${table}")"; then
    BOOTSTRAP_PROCESS_GROUP_LIVENESS="${state}"
  fi
}

bootstrap_setup_lease_read() {
  local lease_file="$1" parsed
  [[ ! -L "${lease_file}" && -f "${lease_file}" ]] || {
    bootstrap_error "setup lease must be a regular file: ${lease_file}"; return 1; }
  parsed="$(awk -F= '
    NR == 1 && $1 == "schema" && ($2 == "1" || $2 == "2") { schema = $2; next }
    NR == 2 && $1 == "owner_pid" && $2 ~ /^[1-9][0-9]*$/ { owner = $2; next }
    schema == 1 && NR == 3 && $1 == "nonce" && $2 ~ /^[A-Za-z0-9._-]+$/ { nonce = $2; next }
    schema == 1 && NR == 4 && $1 == "state" && ($2 == "pending" || $2 == "active") { state = $2; next }
    schema == 1 && NR == 5 && state == "active" && $1 == "leader_pid" && $2 ~ /^[1-9][0-9]*$/ { leader = $2; next }
    schema == 1 && NR == 6 && state == "active" && $1 == "process_group" && $2 ~ /^[1-9][0-9]*$/ { pgid = $2; next }
    schema == 1 && NR == 7 && state == "active" && $1 == "leader_identity" && $2 ~ /^[A-Za-z0-9_:.-]+$/ { identity = $2; next }
    schema == 2 && NR == 3 && $1 == "owner_identity" && $2 ~ /^[A-Za-z0-9_:.-]+$/ { owner_identity = $2; next }
    schema == 2 && NR == 4 && $1 == "nonce" && $2 ~ /^[A-Za-z0-9._-]+$/ { nonce = $2; next }
    schema == 2 && NR == 5 && $1 == "state" && ($2 == "pending" || $2 == "active") { state = $2; next }
    schema == 2 && NR == 6 && state == "active" && $1 == "leader_pid" && $2 ~ /^[1-9][0-9]*$/ { leader = $2; next }
    schema == 2 && NR == 7 && state == "active" && $1 == "process_group" && $2 ~ /^[1-9][0-9]*$/ { pgid = $2; next }
    schema == 2 && NR == 8 && state == "active" && $1 == "leader_identity" && $2 ~ /^[A-Za-z0-9_:.-]+$/ { identity = $2; next }
    { bad = 1 }
    END {
      valid_v1 = schema == 1 && ((state == "pending" && NR == 4) ||
        (state == "active" && NR == 7 && leader != "" && pgid != "" && identity != ""))
      valid_v2 = schema == 2 && owner_identity != "" && ((state == "pending" && NR == 5) ||
        (state == "active" && NR == 8 && leader != "" && pgid != "" && identity != ""))
      if (!bad && owner != "" && nonce != "" && (valid_v1 || valid_v2)) {
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
  local temporary="${lease_file}.write.$$.$RANDOM"
  [[ ! -e "${temporary}" && ! -L "${temporary}" ]] || return 1
  if [[ "${state}" == "pending" ]]; then
    [[ ! -e "${lease_file}" && ! -L "${lease_file}" ]] || return 1
    printf 'schema=2\nowner_pid=%s\nowner_identity=%s\nnonce=%s\nstate=pending\n' \
      "${owner_pid}" "${owner_identity}" "${nonce}" > "${temporary}" || return 1
  elif [[ "${state}" == "active" ]]; then
    printf 'schema=2\nowner_pid=%s\nowner_identity=%s\nnonce=%s\nstate=active\nleader_pid=%s\nprocess_group=%s\nleader_identity=%s\n' \
      "${owner_pid}" "${owner_identity}" "${nonce}" "${leader_pid}" "${pgid}" "${identity}" \
      > "${temporary}" || return 1
  else
    return 1
  fi
  if ! mv -f -- "${temporary}" "${lease_file}"; then
    rm -f -- "${temporary}"
    return 1
  fi
}

bootstrap_setup_lease_liveness() {
  local lease_file="$1" owner_pid="$2" nonce="$3"
  BOOTSTRAP_SETUP_LEASE_LIVENESS="ambiguous"
  bootstrap_setup_lease_read "${lease_file}" || return 0
  [[ "${BOOTSTRAP_LEASE_OWNER_PID}" == "${owner_pid}" \
    && "${BOOTSTRAP_LEASE_NONCE}" == "${nonce}" ]] || return 0
  if [[ "${BOOTSTRAP_LEASE_STATE}" == "pending" ]]; then
    if [[ "${BOOTSTRAP_LEASE_SCHEMA}" == "1" ]]; then
      BOOTSTRAP_SETUP_LEASE_LIVENESS="dead"
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
    && bootstrap_process_snapshot "${BOOTSTRAP_LEASE_LEADER_PID}" \
    && [[ "${BOOTSTRAP_PROCESS_PGID}" == "${BOOTSTRAP_LEASE_PGID}" ]] \
    && [[ "${BOOTSTRAP_PROCESS_IDENTITY}" == "${BOOTSTRAP_LEASE_LEADER_IDENTITY}" ]]; then
    BOOTSTRAP_SETUP_LEASE_LIVENESS="active"
  fi
}

bootstrap_setup_lease_clear_inactive() {
  local lease_file="$1" owner_pid="$2" nonce="$3"
  local evidence="${1}.evidence.$$.$RANDOM" retired="${1}.reap.$$.$RANDOM"
  local marker marker_present=0
  for marker in "${lease_file}.evidence."* "${lease_file}.reap."*; do
    if [[ -e "${marker}" || -L "${marker}" ]]; then
      marker_present=1
      break
    fi
  done
  if [[ ! -e "${lease_file}" && ! -L "${lease_file}" ]]; then
    if [[ "${marker_present}" == "1" ]]; then
      bootstrap_error "setup lease retirement evidence is present; preserving its lock and worktree."
      return 1
    fi
    return 0
  fi
  if [[ "${marker_present}" == "1" ]]; then
    bootstrap_error "setup lease revalidation is already in progress; preserving its lock and worktree."
    return 1
  fi
  bootstrap_setup_lease_liveness "${lease_file}" "${owner_pid}" "${nonce}"
  if [[ "${BOOTSTRAP_SETUP_LEASE_LIVENESS}" != "dead" ]]; then
    bootstrap_error "setup process group is ${BOOTSTRAP_SETUP_LEASE_LIVENESS}; preserving its lock and worktree."
    return 1
  fi
  if [[ -e "${evidence}" || -L "${evidence}" ]] \
    || ! ln -- "${lease_file}" "${evidence}" \
    || [[ -L "${evidence}" || ! -f "${evidence}" || ! "${evidence}" -ef "${lease_file}" ]]; then
    rm -f -- "${evidence}" 2>/dev/null || true
    bootstrap_error "could not preserve inactive setup lease evidence: ${lease_file}"
    return 1
  fi
  bootstrap_setup_lease_liveness "${evidence}" "${owner_pid}" "${nonce}"
  if [[ "${BOOTSTRAP_SETUP_LEASE_LIVENESS}" != "dead" ]]; then
    bootstrap_error "setup process group changed during lease revalidation; preserving its lock and worktree."
    rm -f -- "${evidence}" 2>/dev/null || \
      bootstrap_error "could not remove setup lease evidence after liveness verification: ${evidence}"
    return 1
  fi
  if [[ -e "${retired}" || -L "${retired}" ]] \
    || ! mv -- "${lease_file}" "${retired}" \
    || [[ -L "${retired}" || ! -f "${retired}" || ! "${retired}" -ef "${evidence}" ]]; then
    bootstrap_error "could not retire the revalidated setup lease: ${lease_file}"
    rm -f -- "${evidence}" 2>/dev/null || true
    return 1
  fi
  rm -f -- "${retired}" "${evidence}" || return 1
}

bootstrap_setup_job_is_stopped() {
  local leader_pid="$1" stopped_jobs
  stopped_jobs="$(jobs -s -p 2>/dev/null)" || return 1
  grep -qFx -- "${leader_pid}" <<< "${stopped_jobs}"
}

bootstrap_setup_tty_is_foreground() {
  local terminal_state
  [[ -t 0 ]] || return 1
  terminal_state="$(LC_ALL=C ps -p $$ -o pgid= -o tpgid= 2>/dev/null)" || return 1
  awk 'NF == 2 && $1 ~ /^[1-9][0-9]*$/ && $1 == $2 { ok = 1 }
       NF != 2 { bad = 1 }
       END { exit !(!bad && ok) }' <<< "${terminal_state}"
}

bootstrap_setup_group_signal() {
  local signal="$1" leader_pid="$2" pgid="${3:-}"
  if [[ -n "${pgid}" ]]; then
    kill -s "${signal}" -- "-${pgid}" 2>/dev/null \
      || kill -s "${signal}" "${leader_pid}" 2>/dev/null || true
    kill -s CONT -- "-${pgid}" 2>/dev/null || true
  else
    kill -s "${signal}" "${leader_pid}" 2>/dev/null || true
  fi
}

bootstrap_wait_for_setup_group() {
  local leader_pid="$1" pgid="${2:-}" attempts="${3:-50}" attempt
  for ((attempt = 0; attempt < attempts; attempt += 1)); do
    if [[ -n "${pgid}" ]]; then
      bootstrap_process_group_liveness "${pgid}"
      if [[ "${BOOTSTRAP_PROCESS_GROUP_LIVENESS}" == "dead" ]]; then
        wait "${leader_pid}" 2>/dev/null || true
        return 0
      fi
    elif ! kill -0 "${leader_pid}" 2>/dev/null; then
      wait "${leader_pid}" 2>/dev/null || true
      return 0
    fi
    sleep 0.02
  done
  return 1
}

bootstrap_setup_group_terminate() {
  local leader_pid="$1" pgid="$2"
  bootstrap_setup_group_signal TERM "${leader_pid}" "${pgid}"
  if bootstrap_wait_for_setup_group "${leader_pid}" "${pgid}"; then
    return 0
  fi
  bootstrap_error "setup process group did not exit after TERM; escalating to KILL."
  bootstrap_setup_group_signal KILL "${leader_pid}" "${pgid}"
  if ! bootstrap_wait_for_setup_group "${leader_pid}" "${pgid}"; then
    bootstrap_error "setup process group remains after KILL; preserving setup lease."
    return 1
  fi
}

bootstrap_cancel_setup() {
  local signal="$1" status="$2"
  if [[ "${BOOTSTRAP_SETUP_LAUNCHING:-0}" == "1" \
    && -z "${BOOTSTRAP_SETUP_LEADER_PID:-}" ]]; then
    BOOTSTRAP_SETUP_PENDING_SIGNAL="${signal}"
    BOOTSTRAP_SETUP_PENDING_STATUS="${status}"
    return 0
  fi
  trap - INT TERM HUP
  if [[ -n "${BOOTSTRAP_SETUP_LEADER_PID:-}" && -n "${BOOTSTRAP_SETUP_PGID:-}" ]]; then
    bootstrap_setup_group_signal "${signal}" \
      "${BOOTSTRAP_SETUP_LEADER_PID}" "${BOOTSTRAP_SETUP_PGID}"
    if ! bootstrap_wait_for_setup_group \
      "${BOOTSTRAP_SETUP_LEADER_PID}" "${BOOTSTRAP_SETUP_PGID}"; then
      bootstrap_error \
        "setup process group did not exit after ${signal}; escalating to KILL."
      bootstrap_setup_group_signal KILL \
        "${BOOTSTRAP_SETUP_LEADER_PID}" "${BOOTSTRAP_SETUP_PGID}"
      if ! bootstrap_wait_for_setup_group \
        "${BOOTSTRAP_SETUP_LEADER_PID}" "${BOOTSTRAP_SETUP_PGID}"; then
        bootstrap_error \
          "setup process group remains after KILL; preserving setup lease."
        exit 73
      fi
    fi
  fi
  exit "${status}"
}

bootstrap_run_setup_with_lease() {
  local setup_path="$1" dist_root="$2" owner_pid="$3" nonce="$4"
  shift 4
  local lease_file="${dist_root}/.bootstrap.lock.lease.${nonce}"
  local gate_file="${BOOTSTRAP_TMP}/setup-lease-start" leader_pid setup_rc=0
  local monitor_enabled=0 tty_requested=0 stopped=0 owner_identity
  if ! bootstrap_process_snapshot "${owner_pid}" \
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
    while [[ ! -f "${gate_file}" ]]; do
      bootstrap_process_identity_liveness "${owner_pid}" "${owner_identity}"
      [[ "${BOOTSTRAP_PROCESS_IDENTITY_LIVENESS}" == "active" ]] || exit 125
      sleep 0.02
    done
    exec env PYTHONDONTWRITEBYTECODE=1 bash "${setup_path}" "$@"
  ) &
  leader_pid=$!
  BOOTSTRAP_SETUP_LEADER_PID="${leader_pid}"
  BOOTSTRAP_SETUP_LAUNCHING=0
  if [[ -n "${BOOTSTRAP_SETUP_PENDING_SIGNAL:-}" ]]; then
    bootstrap_cancel_setup "${BOOTSTRAP_SETUP_PENDING_SIGNAL}" "${BOOTSTRAP_SETUP_PENDING_STATUS}"
  fi
  if ! bootstrap_process_snapshot "${leader_pid}" \
    || [[ "${BOOTSTRAP_PROCESS_PGID}" != "${leader_pid}" ]] \
    || [[ "${BOOTSTRAP_PROCESS_STATE}" == Z* ]]; then
    if ! bootstrap_setup_group_terminate "${leader_pid}" "${leader_pid}"; then
      [[ "${monitor_enabled}" == "1" ]] || set +m
      bootstrap_error "could not terminate the unverified setup process group."
      return 73
    fi
    [[ "${monitor_enabled}" == "1" ]] || set +m
    bootstrap_error "could not establish an isolated setup process group."
    return 1
  fi
  BOOTSTRAP_SETUP_PGID="${BOOTSTRAP_PROCESS_PGID}"
  if [[ "${tty_requested}" == "1" ]]; then
    kill -s STOP -- "-${BOOTSTRAP_SETUP_PGID}" 2>/dev/null || true
    for _bootstrap_stop_attempt in {1..100}; do
      if bootstrap_setup_job_is_stopped "${leader_pid}"; then stopped=1; break; fi
      sleep 0.02
    done
    if [[ "${stopped}" != "1" ]]; then
      bootstrap_setup_group_terminate "${leader_pid}" "${BOOTSTRAP_SETUP_PGID}"
      [[ "${monitor_enabled}" == "1" ]] || set +m
      bootstrap_error "could not stop the isolated setup process group before publication."
      return 1
    fi
  fi
  if ! bootstrap_setup_lease_write "${lease_file}" "${owner_pid}" "${nonce}" active \
      "${owner_identity}" "${leader_pid}" "${BOOTSTRAP_SETUP_PGID}" \
      "${BOOTSTRAP_PROCESS_IDENTITY}" \
    || ! : > "${gate_file}"; then
    bootstrap_error "could not publish the setup process-group gate."
    if ! bootstrap_setup_group_terminate "${leader_pid}" "${BOOTSTRAP_SETUP_PGID}"; then
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
      bootstrap_setup_group_terminate "${leader_pid}" "${BOOTSTRAP_SETUP_PGID}"
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
  [[ "${monitor_enabled}" == "1" ]] || set +m
  bootstrap_setup_lease_clear_inactive "${lease_file}" "${owner_pid}" "${nonce}" || return 73
  BOOTSTRAP_SETUP_LEASE_HELD=0 BOOTSTRAP_SETUP_LEASE_FILE=""
  BOOTSTRAP_SETUP_LEADER_PID="" BOOTSTRAP_SETUP_PGID=""
  return "${setup_rc}"
}

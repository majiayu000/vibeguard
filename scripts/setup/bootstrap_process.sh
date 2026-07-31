#!/usr/bin/env bash
# Process-group and setup-lease helpers for the pinned payload bootstrap.

bootstrap_process_snapshot() {
  local expected_pid="$1" snapshot parsed
  BOOTSTRAP_PROCESS_PGID="" BOOTSTRAP_PROCESS_IDENTITY=""
  snapshot="$(LC_ALL=C ps -p "${expected_pid}" -o pid= -o pgid= -o lstart= 2>/dev/null)" || return 1
  parsed="$(awk -v expected="${expected_pid}" '
    NF == 7 && $1 == expected && $1 ~ /^[1-9][0-9]*$/ && $2 ~ /^[1-9][0-9]*$/ {
      if ($3 !~ /^[A-Z][a-z][a-z]$/ || $4 !~ /^[A-Z][a-z][a-z]$/ ||
          $5 !~ /^[0-9][0-9]?$/ || $6 !~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/ ||
          $7 !~ /^[0-9][0-9][0-9][0-9]$/) bad = 1
      count += 1
      pgid = $2
      identity = $3 "_" $4 "_" $5 "_" $6 "_" $7
      next
    }
    NF { bad = 1 }
    END {
      if (!bad && count == 1) print pgid "\t" identity
      else exit 1
    }
  ' <<< "${snapshot}")" || return 1
  IFS=$'\t' read -r BOOTSTRAP_PROCESS_PGID BOOTSTRAP_PROCESS_IDENTITY <<< "${parsed}"
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
    NR == 1 && $1 == "schema" && $2 == "1" { schema = $2; next }
    NR == 2 && $1 == "owner_pid" && $2 ~ /^[1-9][0-9]*$/ { owner = $2; next }
    NR == 3 && $1 == "nonce" && $2 ~ /^[A-Za-z0-9._-]+$/ { nonce = $2; next }
    NR == 4 && $1 == "state" && ($2 == "pending" || $2 == "active") { state = $2; next }
    NR == 5 && state == "active" && $1 == "leader_pid" && $2 ~ /^[1-9][0-9]*$/ { leader = $2; next }
    NR == 6 && state == "active" && $1 == "process_group" && $2 ~ /^[1-9][0-9]*$/ { pgid = $2; next }
    NR == 7 && state == "active" && $1 == "leader_identity" && $2 ~ /^[A-Za-z0-9_:.-]+$/ { identity = $2; next }
    { bad = 1 }
    END {
      if (!bad && schema == 1 && owner != "" && nonce != "" &&
          ((state == "pending" && NR == 4) ||
           (state == "active" && NR == 7 && leader != "" && pgid != "" && identity != ""))) {
        print owner "\t" nonce "\t" state "\t" leader "\t" pgid "\t" identity
      } else exit 1
    }
  ' "${lease_file}")" || {
    bootstrap_error "setup lease metadata is malformed: ${lease_file}"; return 1; }
  IFS=$'\t' read -r BOOTSTRAP_LEASE_OWNER_PID BOOTSTRAP_LEASE_NONCE \
    BOOTSTRAP_LEASE_STATE BOOTSTRAP_LEASE_LEADER_PID BOOTSTRAP_LEASE_PGID \
    BOOTSTRAP_LEASE_LEADER_IDENTITY <<< "${parsed}"
}

bootstrap_setup_lease_write() {
  local lease_file="$1" owner_pid="$2" nonce="$3" state="$4"
  local leader_pid="${5:-}" pgid="${6:-}" identity="${7:-}" temporary="${lease_file}.write.$$.$RANDOM"
  [[ ! -e "${temporary}" && ! -L "${temporary}" ]] || return 1
  if [[ "${state}" == "pending" ]]; then
    [[ ! -e "${lease_file}" && ! -L "${lease_file}" ]] || return 1
    printf 'schema=1\nowner_pid=%s\nnonce=%s\nstate=pending\n' \
      "${owner_pid}" "${nonce}" > "${temporary}" || return 1
  elif [[ "${state}" == "active" ]]; then
    printf 'schema=1\nowner_pid=%s\nnonce=%s\nstate=active\nleader_pid=%s\nprocess_group=%s\nleader_identity=%s\n' \
      "${owner_pid}" "${nonce}" "${leader_pid}" "${pgid}" "${identity}" \
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
  if [[ "${BOOTSTRAP_LEASE_STATE}" != "active" ]]; then
    BOOTSTRAP_SETUP_LEASE_LIVENESS="dead"
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
  local lease_file="$1" owner_pid="$2" nonce="$3" claimed="${1}.reap.$$.$RANDOM"
  [[ ! -e "${lease_file}" && ! -L "${lease_file}" ]] && return 0
  bootstrap_setup_lease_liveness "${lease_file}" "${owner_pid}" "${nonce}"
  if [[ "${BOOTSTRAP_SETUP_LEASE_LIVENESS}" != "dead" ]]; then
    bootstrap_error "setup process group is ${BOOTSTRAP_SETUP_LEASE_LIVENESS}; preserving its lock and worktree."
    return 1
  fi
  if [[ -e "${claimed}" || -L "${claimed}" ]] || ! mv -- "${lease_file}" "${claimed}"; then
    bootstrap_error "could not claim inactive setup lease: ${lease_file}"
    return 1
  fi
  bootstrap_setup_lease_liveness "${claimed}" "${owner_pid}" "${nonce}"
  if [[ "${BOOTSTRAP_SETUP_LEASE_LIVENESS}" != "dead" ]]; then
    bootstrap_error "setup process group changed during lease claim; preserving its lock and worktree."
    if [[ ! -e "${lease_file}" && ! -L "${lease_file}" ]]; then
      mv -- "${claimed}" "${lease_file}" || \
        bootstrap_error "could not restore setup lease after liveness verification: ${claimed}"
    fi
    return 1
  fi
  rm -f -- "${claimed}" || return 1
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

bootstrap_setup_group_terminate() {
  local leader_pid="$1" pgid="$2"
  kill -s TERM -- "-${pgid}" 2>/dev/null || kill -s TERM "${leader_pid}" 2>/dev/null || true
  kill -s CONT -- "-${pgid}" 2>/dev/null || true
  wait "${leader_pid}" 2>/dev/null || true
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
    kill -s "${signal}" -- "-${BOOTSTRAP_SETUP_PGID}" 2>/dev/null \
      || kill -s "${signal}" "${BOOTSTRAP_SETUP_LEADER_PID}" 2>/dev/null || true
    kill -s CONT -- "-${BOOTSTRAP_SETUP_PGID}" 2>/dev/null || true
    wait "${BOOTSTRAP_SETUP_LEADER_PID}" 2>/dev/null || true
  fi
  exit "${status}"
}

bootstrap_run_setup_with_lease() {
  local setup_path="$1" dist_root="$2" owner_pid="$3" nonce="$4"
  shift 4
  local lease_file="${dist_root}/.bootstrap.lock.lease.${nonce}"
  local gate_file="${BOOTSTRAP_TMP}/setup-lease-start" leader_pid setup_rc=0
  local monitor_enabled=0 tty_requested=0 stopped=0
  bootstrap_setup_lease_write "${lease_file}" "${owner_pid}" "${nonce}" pending || return 1
  BOOTSTRAP_SETUP_LEASE_FILE="${lease_file}" BOOTSTRAP_SETUP_LEASE_HELD=1
  [[ $- == *m* ]] && monitor_enabled=1
  [[ -t 0 ]] && tty_requested=1
  set -m
  BOOTSTRAP_SETUP_LAUNCHING=1
  (
    while [[ ! -f "${gate_file}" ]]; do
      kill -0 "${owner_pid}" 2>/dev/null || exit 125
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
    || [[ "${BOOTSTRAP_PROCESS_PGID}" != "${leader_pid}" ]]; then
    bootstrap_setup_group_terminate "${leader_pid}" "${leader_pid}"
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
      "${leader_pid}" "${BOOTSTRAP_SETUP_PGID}" "${BOOTSTRAP_PROCESS_IDENTITY}" \
    || ! : > "${gate_file}"; then
    bootstrap_error "could not publish the setup process-group gate."
    bootstrap_setup_group_terminate "${leader_pid}" "${BOOTSTRAP_SETUP_PGID}"
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

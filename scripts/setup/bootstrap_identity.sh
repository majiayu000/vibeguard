#!/usr/bin/env bash
# Collision-resistant process birth identity for Linux and Darwin bootstrap supervision.

bootstrap_process_identity_is_strong() {
  [[ "$1" =~ ^linux-v1:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[0-9]+$ \
    || "$1" =~ ^darwin-v1:[0-9]+:[0-9]{6}$ ]]
}

bootstrap_linux_process_snapshot_from_records() {
  local expected_pid="$1" record="$2" boot_id="$3" rest had_noglob=0
  local state pgid start_ticks
  [[ "${expected_pid}" =~ ^[1-9][0-9]*$ \
    && "${record}" == "${expected_pid} "* \
    && "${record}" == *") "* \
    && "${boot_id}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
    || return 1
  rest="${record##*) }"
  [[ $- == *f* ]] && had_noglob=1
  set -f
  # shellcheck disable=SC2086 # Kernel stat fields require intentional word splitting.
  set -- ${rest}
  [[ "${had_noglob}" == "1" ]] || set +f
  [[ $# -ge 20 ]] || return 1
  state="$1" pgid="$3" start_ticks="${20}"
  [[ "${state}" =~ ^[A-Za-z]$ \
    && "${pgid}" =~ ^[1-9][0-9]*$ \
    && "${start_ticks}" =~ ^[0-9]+$ ]] || return 1
  BOOTSTRAP_PROCESS_PGID="${pgid}"
  BOOTSTRAP_PROCESS_STATE="${state}"
  BOOTSTRAP_PROCESS_IDENTITY="linux-v1:${boot_id}:${start_ticks}"
  BOOTSTRAP_PROCESS_IDENTITY_STRENGTH="strong"
}

bootstrap_linux_process_snapshot() {
  local expected_pid="$1" record boot_id
  [[ -r "/proc/${expected_pid}/stat" \
    && -r /proc/sys/kernel/random/boot_id ]] || return 1
  record="$(<"/proc/${expected_pid}/stat")" || return 1
  boot_id="$(</proc/sys/kernel/random/boot_id)" || return 1
  bootstrap_linux_process_snapshot_from_records \
    "${expected_pid}" "${record}" "${boot_id}"
}

bootstrap_darwin_process_snapshot_from_output() {
  local expected_pid="$1" output="$2" parsed_pid pgid status start_sec start_usec extra
  [[ "${output}" != *$'\n'* ]] || return 1
  IFS=$'\t' read -r parsed_pid pgid status start_sec start_usec extra <<< "${output}"
  [[ -z "${extra}" \
    && "${parsed_pid}" == "${expected_pid}" \
    && "${pgid}" =~ ^[1-9][0-9]*$ \
    && "${status}" =~ ^[1-5]$ \
    && "${start_sec}" =~ ^[1-9][0-9]*$ \
    && "${start_usec}" =~ ^[0-9]+$ \
    && "${start_usec}" -lt 1000000 ]] || return 1
  BOOTSTRAP_PROCESS_PGID="${pgid}"
  [[ "${status}" == "5" ]] \
    && BOOTSTRAP_PROCESS_STATE="Z" || BOOTSTRAP_PROCESS_STATE="S"
  printf -v start_usec '%06d' "${start_usec}"
  BOOTSTRAP_PROCESS_IDENTITY="darwin-v1:${start_sec}:${start_usec}"
  BOOTSTRAP_PROCESS_IDENTITY_STRENGTH="strong"
}

bootstrap_darwin_process_snapshot() {
  local expected_pid="$1" output
  [[ -x /usr/bin/osascript \
    && -f "${BOOTSTRAP_BIRTH_TOKEN_JXA}" \
    && ! -L "${BOOTSTRAP_BIRTH_TOKEN_JXA}" ]] || return 1
  output="$(/usr/bin/osascript -l JavaScript \
    "${BOOTSTRAP_BIRTH_TOKEN_JXA}" "${expected_pid}" 2>/dev/null)" || return 1
  bootstrap_darwin_process_snapshot_from_output "${expected_pid}" "${output}"
}

bootstrap_strong_process_snapshot() {
  local expected_pid="$1" kernel
  kernel="$(command -p uname -s 2>/dev/null)" || return 1
  case "${kernel}" in
    Linux) bootstrap_linux_process_snapshot "${expected_pid}" ;;
    Darwin) bootstrap_darwin_process_snapshot "${expected_pid}" ;;
    *) return 1 ;;
  esac
}

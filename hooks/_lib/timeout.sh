#!/usr/bin/env bash
# Shared timeout runner for hook-side subprocesses.

if [[ -n "${_VG_TIMEOUT_SH_LOADED:-}" ]]; then
  return 0
fi
_VG_TIMEOUT_SH_LOADED=1

vg_timeout_kill_tree() {
  local signal="$1" root_pid="$2" child
  [[ -n "${root_pid}" ]] || return 0

  if command -v pgrep >/dev/null 2>&1; then
    for child in $(pgrep -P "${root_pid}" 2>/dev/null || true); do
      vg_timeout_kill_tree "${signal}" "${child}"
    done
  fi
  kill "-${signal}" "${root_pid}" 2>/dev/null || true
}

vg_run_with_timeout() {
  local seconds="$1"
  shift

  if command -v timeout >/dev/null 2>&1; then
    timeout "${seconds}" "$@"
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "${seconds}" "$@"
    return $?
  fi

  local flag stdin_file pid watchdog command_status stdin_is_tty
  flag="$(mktemp "${TMPDIR:-/tmp}/vibeguard-timeout.XXXXXX")"
  stdin_file="$(mktemp "${TMPDIR:-/tmp}/vibeguard-timeout-stdin.XXXXXX")"

  stdin_is_tty=0
  [[ -t 0 ]] && stdin_is_tty=1
  if ! exec 9<&0; then
    rm -f "${flag}" "${stdin_file}" 2>/dev/null || true
    return 1
  fi

  (
    if [[ "${stdin_is_tty}" -eq 1 ]]; then
      : > "${stdin_file}"
    elif ! cat <&9 > "${stdin_file}"; then
      exit 1
    fi
    exec 9<&-
    exec "$@" < "${stdin_file}"
  ) &
  pid=$!
  exec 9<&-
  (
    local sleep_pid
    sleep "${seconds}" 2>/dev/null &
    sleep_pid=$!
    trap 'kill "${sleep_pid}" 2>/dev/null || true; exit 0' TERM INT
    wait "${sleep_pid}" 2>/dev/null || true
    if kill -0 "${pid}" 2>/dev/null; then
      printf 'timeout\n' >"${flag}" 2>/dev/null || true
      vg_timeout_kill_tree TERM "${pid}"
      sleep 0.2 2>/dev/null || true
      vg_timeout_kill_tree KILL "${pid}"
    fi
  ) &
  watchdog=$!

  wait "${pid}" 2>/dev/null
  command_status=$?
  kill "${watchdog}" 2>/dev/null || true
  wait "${watchdog}" 2>/dev/null || true

  if [[ -s "${flag}" ]]; then
    rm -f "${flag}" "${stdin_file}" 2>/dev/null || true
    return 124
  fi
  rm -f "${flag}" "${stdin_file}" 2>/dev/null || true
  return "${command_status}"
}

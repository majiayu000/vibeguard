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

  local flag stdin_file pid watchdog command_status
  flag="$(mktemp "${TMPDIR:-/tmp}/vibeguard-timeout.XXXXXX")"
  stdin_file="$(mktemp "${TMPDIR:-/tmp}/vibeguard-timeout-stdin.XXXXXX")"
  if [[ -t 0 ]]; then
    : > "${stdin_file}"
  elif ! cat > "${stdin_file}"; then
    rm -f "${flag}" "${stdin_file}" 2>/dev/null || true
    return 1
  fi

  "$@" < "${stdin_file}" &
  pid=$!
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

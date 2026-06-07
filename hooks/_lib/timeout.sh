#!/usr/bin/env bash
# Shared timeout runner for hook-side subprocesses.

if [[ -n "${_VG_TIMEOUT_SH_LOADED:-}" ]]; then
  return 0
fi
_VG_TIMEOUT_SH_LOADED=1

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

  local flag pid watchdog status
  flag="$(mktemp "${TMPDIR:-/tmp}/vibeguard-timeout.XXXXXX")"
  "$@" &
  pid=$!
  (
    local sleep_pid
    sleep "${seconds}" 2>/dev/null &
    sleep_pid=$!
    trap 'kill "${sleep_pid}" 2>/dev/null || true; exit 0' TERM INT
    wait "${sleep_pid}" 2>/dev/null || true
    if kill -0 "${pid}" 2>/dev/null; then
      printf 'timeout\n' >"${flag}" 2>/dev/null || true
      kill -TERM "${pid}" 2>/dev/null || true
      sleep 0.2 2>/dev/null || true
      kill -KILL "${pid}" 2>/dev/null || true
    fi
  ) &
  watchdog=$!

  wait "${pid}" 2>/dev/null
  status=$?
  kill "${watchdog}" 2>/dev/null || true
  wait "${watchdog}" 2>/dev/null || true

  if [[ -s "${flag}" ]]; then
    rm -f "${flag}" 2>/dev/null || true
    return 124
  fi
  rm -f "${flag}" 2>/dev/null || true
  return "${status}"
}

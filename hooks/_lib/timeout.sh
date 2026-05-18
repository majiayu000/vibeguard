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

  python3 - "${seconds}" "$@" <<'PY'
import subprocess
import sys

timeout_seconds = float(sys.argv[1])
command = sys.argv[2:]
try:
    completed = subprocess.run(command, timeout=timeout_seconds)
except subprocess.TimeoutExpired:
    raise SystemExit(124)
raise SystemExit(completed.returncode)
PY
}

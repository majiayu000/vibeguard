#!/usr/bin/env bash
# Timer helper for hooks/log.sh.

#Timer: call vg_start_timer at the beginning of the hook, vg_log automatically calculates the time consumption
_VG_START_MS=""
vg_start_timer() {
  if command -v perl &>/dev/null; then
    _VG_START_MS=$(perl -MTime::HiRes=time -e 'printf "%.0f", time*1000')
  else
    _VG_START_MS=$(date +%s)000
  fi
}

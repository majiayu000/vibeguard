#!/usr/bin/env bash
# Compatibility entry point; the canonical GO-08 implementation lives in vibeguard-runtime.
source "$(dirname "$0")/runtime-shim.sh"
run_runtime_guard go defer-in-loop "$@"

#!/usr/bin/env bash
# Compatibility entry point; the canonical TS-01/TS-02 implementation lives in vibeguard-runtime.
source "$(dirname "$0")/runtime-shim.sh"
run_runtime_guard typescript any-abuse "$@"

#!/usr/bin/env bash
# Compatibility entry point; the canonical GO-01 implementation lives in vibeguard-runtime.
source "$(dirname "$0")/runtime-shim.sh"
run_runtime_guard go error-handling "$@"

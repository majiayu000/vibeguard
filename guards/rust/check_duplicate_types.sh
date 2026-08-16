#!/usr/bin/env bash
# Compatibility entry point; the canonical RS-05 implementation lives in vibeguard-runtime.
source "$(dirname "$0")/runtime-shim.sh"
run_runtime_guard rust duplicate-types "$@"

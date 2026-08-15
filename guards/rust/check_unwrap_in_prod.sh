#!/usr/bin/env bash
# Compatibility entry point; the canonical RS-03 implementation lives in vibeguard-runtime.
source "$(dirname "$0")/runtime-shim.sh"
run_runtime_guard rust unwrap "$@"

#!/usr/bin/env bash
# Compatibility entry point; the canonical TS-03 implementation lives in vibeguard-runtime.
source "$(dirname "$0")/runtime-shim.sh"
run_runtime_guard typescript console-residual "$@"

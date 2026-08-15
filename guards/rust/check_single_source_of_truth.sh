#!/usr/bin/env bash
# Compatibility entry point; the canonical RS-12 implementation lives in vibeguard-runtime.
source "$(dirname "$0")/runtime-shim.sh"
run_runtime_guard rust single-source-of-truth "$@"

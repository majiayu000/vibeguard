#!/usr/bin/env bash
# Compatibility entry point; the canonical duplication implementation lives in vibeguard-runtime.
source "$(dirname "$0")/runtime-shim.sh"
run_runtime_guard typescript duplicate-constants "$@"

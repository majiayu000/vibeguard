#!/usr/bin/env bash
# Compatibility entry point; the canonical TASTE implementation lives in vibeguard-runtime.
source "$(dirname "$0")/runtime-shim.sh"
run_runtime_guard rust taste-invariants "$@"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
hook_test_init

REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

header "log.sh — runtime resolution: release preferred over debug; override wins"
# =========================================================
#
# hooks/log.sh resolves the vibeguard-runtime binary from an ordered candidate
# list. The ordering is load-bearing: a debug build shadowing the release build
# distorts hook latency benchmarks (GH-551 SP551-T1). This shard pins two
# invariants against regression (a prior commit had them reversed):
#
#   1. With both target/release and target/debug binaries present and no
#      VIBEGUARD_RUNTIME override, the release binary is selected.
#   2. An explicit VIBEGUARD_RUNTIME override takes precedence over both.
#
# The real hooks/log.sh is sourced in an isolated bash process so the actual
# resolution code is exercised (no copied logic). Sourcing only resolves the
# path and sources the _lib helpers; it does not execute the runtime.

_release_bin="${REPO_DIR}/vibeguard-runtime/target/release/vibeguard-runtime"
_debug_bin="${REPO_DIR}/vibeguard-runtime/target/debug/vibeguard-runtime"

# tests/test_hooks.sh builds the release binary before running shards. When this
# shard runs standalone without that build, skip loudly rather than pass falsely.
if [[ ! -x "$_release_bin" ]]; then
  red "release binary missing at ${_release_bin} — run tests/test_hooks.sh (builds it) or cargo build --release"
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
  hook_test_finish
fi

# Ensure a debug binary also exists so the ordering is actually contested.
# target/ is gitignored; remove the stub afterward if we created it.
_created_debug=false
if [[ ! -e "$_debug_bin" ]]; then
  mkdir -p "$(dirname "$_debug_bin")"
  printf '#!/bin/sh\nexit 0\n' > "$_debug_bin"
  chmod +x "$_debug_bin"
  _created_debug=true
fi

_cleanup() {
  if [[ "$_created_debug" == "true" ]]; then
    rm -f "$_debug_bin" 2>/dev/null || true
  fi
}
trap _cleanup EXIT

# --- Test 1: release wins over debug when no override is set ---
# HOME is redirected to an empty dir so an installed binary under
# ~/.vibeguard cannot influence the dev-context ordering.
_resolved_default=$(
  _tmp_home=$(mktemp -d)
  env -u VIBEGUARD_RUNTIME HOME="$_tmp_home" \
    bash -c 'source "'"${REPO_DIR}"'/hooks/log.sh" >/dev/null 2>&1; printf "%s" "$_VIBEGUARD_RUNTIME"'
  rm -rf "$_tmp_home"
)
assert_contains "$_resolved_default" "/target/release/vibeguard-runtime" \
  "release binary is selected when both release and debug are present"
assert_not_contains "$_resolved_default" "/target/debug/vibeguard-runtime" \
  "debug binary must not shadow the release binary"

# --- Test 2: explicit VIBEGUARD_RUNTIME override takes precedence ---
_resolved_override=$(
  _tmp_home=$(mktemp -d)
  VIBEGUARD_RUNTIME="$_debug_bin" HOME="$_tmp_home" \
    bash -c 'source "'"${REPO_DIR}"'/hooks/log.sh" >/dev/null 2>&1; printf "%s" "$_VIBEGUARD_RUNTIME"'
  rm -rf "$_tmp_home"
)
assert_contains "$_resolved_override" "$_debug_bin" \
  "explicit VIBEGUARD_RUNTIME override is honored ahead of release/debug discovery"

hook_test_finish

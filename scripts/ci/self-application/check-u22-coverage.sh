#!/usr/bin/env bash
# U-22 self-application: enforce the measured Rust line-coverage baseline.
set -euo pipefail

REPO_DIR="${1:-$(cd "$(dirname "$0")/../../.." && pwd)}"
RUNTIME_MANIFEST="${REPO_DIR}/vibeguard-runtime/Cargo.toml"
CARGO_BIN="${VIBEGUARD_U22_CARGO_BIN:-cargo}"
CARGO_LLVM_COV_VERSION="0.8.7"
LINE_COVERAGE_BASELINE="72"
LINE_COVERAGE_TARGET="80"

if [[ ! -f "${RUNTIME_MANIFEST}" ]]; then
  echo "ERROR: U-22 coverage manifest is missing: ${RUNTIME_MANIFEST}" >&2
  exit 1
fi

if ! version_output="$("${CARGO_BIN}" llvm-cov --version 2>&1)"; then
  echo "ERROR: cargo-llvm-cov ${CARGO_LLVM_COV_VERSION} is required for the U-22 coverage gate" >&2
  printf '%s\n' "${version_output}" >&2
  exit 1
fi

expected_version="cargo-llvm-cov ${CARGO_LLVM_COV_VERSION}"
if [[ "${version_output}" != "${expected_version}" ]]; then
  echo "ERROR: U-22 coverage gate requires ${expected_version}; found ${version_output}" >&2
  exit 1
fi

echo "U-22 Rust line coverage: blocking baseline=${LINE_COVERAGE_BASELINE}%, target=${LINE_COVERAGE_TARGET}% (target not yet enforced)"
set +e
"${CARGO_BIN}" llvm-cov \
  --locked \
  --manifest-path "${RUNTIME_MANIFEST}" \
  --summary-only \
  --fail-under-lines "${LINE_COVERAGE_BASELINE}"
coverage_status=$?
set -e

if [[ "${coverage_status}" -ne 0 ]]; then
  echo "ERROR: U-22 Rust line coverage fell below the ${LINE_COVERAGE_BASELINE}% blocking baseline or coverage execution failed" >&2
  exit "${coverage_status}"
fi

echo "OK: U-22 measured Rust line coverage is at or above the ${LINE_COVERAGE_BASELINE}% blocking baseline"

#!/usr/bin/env bash
# Validate the runtime release workflow contract.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="${REPO_DIR}/.github/workflows/release.yml"
VERSION_FILE="${REPO_DIR}/vibeguard-runtime/VERSION"
CARGO_TOML="${REPO_DIR}/vibeguard-runtime/Cargo.toml"
RUST_TOOLCHAIN="${REPO_DIR}/rust-toolchain.toml"
INSTALL_SH="${REPO_DIR}/scripts/setup/install.sh"
SETUP_LIB="${REPO_DIR}/scripts/setup/lib.sh"

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header(){ printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

assert_cmd() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (cmd: $*)"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local text="$1" expected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qF -- "$expected" <<< "$text"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected to contain: $expected)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local text="$1" forbidden="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qF -- "$forbidden" <<< "$text"; then
    red "$desc (must not contain: $forbidden)"
    FAIL=$((FAIL + 1))
  else
    green "$desc"
    PASS=$((PASS + 1))
  fi
}

assert_regex() {
  local text="$1" regex="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if grep -Eq -- "$regex" <<< "$text"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected regex: $regex)"
    FAIL=$((FAIL + 1))
  fi
}

ensure_runtime_tag_available() {
  local tag="$1"
  if git -C "${REPO_DIR}" rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
    return 0
  fi
  if git -C "${REPO_DIR}" remote get-url origin >/dev/null 2>&1; then
    git -C "${REPO_DIR}" fetch --quiet --depth=1 origin "refs/tags/${tag}:refs/tags/${tag}" >/dev/null 2>&1 || true
  fi
  git -C "${REPO_DIR}" rev-parse -q --verify "refs/tags/${tag}" >/dev/null
}

workflow_text="$(<"${WORKFLOW}")"
toolchain_text="$(<"${RUST_TOOLCHAIN}")"
install_text="$(<"${INSTALL_SH}")"
setup_lib_text="$(<"${SETUP_LIB}")"
runtime_version="$(tr -d '[:space:]' < "${VERSION_FILE}")"
cargo_version="$(
  python3 - "${CARGO_TOML}" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r'(?m)^version = "([^"]+)"$', text)
if not match:
    raise SystemExit("missing package version")
print(match.group(1))
PY
)"

header "release workflow contract"
assert_contains "$workflow_text" $'permissions:\n  contents: read' "workflow default token is read-only"
assert_contains "$workflow_text" $'publish-release:\n    name: Publish release assets' "publish job exists"
assert_contains "$workflow_text" $'permissions:\n      contents: write' "publish job owns release-write token"
assert_contains "$workflow_text" "persist-credentials: false" "non-publish checkouts do not persist credentials"
assert_not_contains "$workflow_text" "--clobber" "release assets are immutable by default"
assert_contains "$workflow_text" "refusing to mutate release assets" "existing release fails closed"
assert_contains "$workflow_text" "git merge-base --is-ancestor" "tag must be reachable from main"
assert_contains "$workflow_text" "RUNTIME_VERSION_FILE" "workflow reads runtime VERSION file"
assert_contains "$workflow_text" "release tag \${TAG_NAME} does not match" "tag/version mismatch fails loudly"
assert_contains "$workflow_text" 'RUST_VERSION: "1.95.0"' "release workflow pins Rust release toolchain"
assert_contains "$toolchain_text" 'channel = "1.95.0"' "repo rust-toolchain pins the same release toolchain"
assert_not_contains "$workflow_text" 'RUST_VERSION: "stable"' "release workflow does not use moving stable Rust"
assert_regex "$workflow_text" 'uses: actions/checkout@[0-9a-f]{40}[[:space:]]*# v6\.0\.2' "checkout action is pinned to a full commit SHA"
assert_regex "$workflow_text" 'uses: actions/upload-artifact@[0-9a-f]{40}[[:space:]]*# v7\.0\.1' "upload-artifact action is pinned to a full commit SHA"
assert_regex "$workflow_text" 'uses: actions/download-artifact@[0-9a-f]{40}[[:space:]]*# v8\.0\.1' "download-artifact action is pinned to a full commit SHA"
assert_regex "$workflow_text" 'uses: actions/attest-build-provenance@[0-9a-f]{40}[[:space:]]*# v4\.1\.0' "attestation action is pinned to a full commit SHA"
assert_contains "$workflow_text" "attestations: write" "build job can publish artifact attestations"
assert_contains "$workflow_text" "id-token: write" "build job can request OIDC token for attestations"
assert_contains "$workflow_text" "subject-path: dist/\${{ matrix.target }}/vibeguard-runtime-\${{ matrix.target }}" "release workflow attests each runtime artifact"
assert_contains "$workflow_text" "sha256sum vibeguard-runtime-* | sort -k2 > SHA256SUMS" "checksums use deterministic sorted layout"
assert_contains "$workflow_text" 'GH_REPO: ${{ github.repository }}' "publish job pins gh target repository"
assert_contains "$setup_lib_text" "gh attestation verify" "setup verifies runtime release attestations when gh is available"
assert_contains "$setup_lib_text" "--signer-workflow" "setup pins provenance signer workflow"
assert_contains "$setup_lib_text" '--source-ref "refs/tags/${tag}"' "setup pins provenance to the release tag"
assert_contains "$install_text" "provenance=verified-provenance" "install output reports verified provenance"
assert_contains "$install_text" "provenance=checksum-only" "install output reports checksum-only fallback explicitly"

for target in \
  aarch64-apple-darwin \
  x86_64-apple-darwin \
  x86_64-unknown-linux-musl \
  aarch64-unknown-linux-musl
do
  assert_contains "$workflow_text" "target: ${target}" "release matrix includes ${target}"
done

header "runtime version contract"
assert_cmd "runtime VERSION is non-empty" test -n "${runtime_version}"
TOTAL=$((TOTAL + 1))
if [[ "${runtime_version}" == "${cargo_version}" ]]; then
  green "runtime VERSION matches Cargo package version"
  PASS=$((PASS + 1))
else
  red "runtime VERSION mismatch (VERSION=${runtime_version}, Cargo.toml=${cargo_version})"
  FAIL=$((FAIL + 1))
fi
runtime_tag="v${runtime_version}"
TOTAL=$((TOTAL + 1))
if ensure_runtime_tag_available "${runtime_tag}"; then
  if git -C "${REPO_DIR}" diff --quiet "${runtime_tag}..HEAD" -- vibeguard-runtime; then
    green "runtime VERSION tag has no newer runtime source changes"
    PASS=$((PASS + 1))
  else
    red "runtime source changed since ${runtime_tag}; bump vibeguard-runtime/VERSION and Cargo.toml before merging"
    FAIL=$((FAIL + 1))
  fi
else
  green "runtime VERSION does not reuse an existing release tag"
  PASS=$((PASS + 1))
fi

printf '\n==============================\n'
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' "$TOTAL" "$PASS" "$FAIL"
printf '==============================\n'

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi

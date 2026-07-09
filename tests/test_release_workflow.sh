#!/usr/bin/env bash
# Validate the runtime release workflow contract.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="${REPO_DIR}/.github/workflows/release.yml"
CI_WORKFLOW="${REPO_DIR}/.github/workflows/ci.yml"
VERSION_FILE="${REPO_DIR}/vibeguard-runtime/VERSION"
CARGO_TOML="${REPO_DIR}/vibeguard-runtime/Cargo.toml"
RUST_TOOLCHAIN="${REPO_DIR}/rust-toolchain.toml"
INSTALL_SH="${REPO_DIR}/scripts/setup/install.sh"
SETUP_LIB="${REPO_DIR}/scripts/setup/lib.sh"
RELEASE_MANIFEST_SCRIPT="${REPO_DIR}/scripts/ci/generate_runtime_release_manifest.py"
DENY_TOML="${REPO_DIR}/deny.toml"
LINUX_SETUP="${REPO_DIR}/docs/linux-setup.md"
INSTALL_SPEC="${REPO_DIR}/docs/specs/install-friction-reduction.md"

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

assert_before() {
  local text="$1" first="$2" second="$3" desc="$4"
  local first_line second_line
  TOTAL=$((TOTAL + 1))
  first_line="$(grep -nF -- "$first" <<< "$text" | head -n 1 | cut -d: -f1 || true)"
  second_line="$(grep -nF -- "$second" <<< "$text" | head -n 1 | cut -d: -f1 || true)"
  if [[ -n "${first_line}" && -n "${second_line}" && "${first_line}" -lt "${second_line}" ]]; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected '$first' before '$second')"
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
ci_text="$(<"${CI_WORKFLOW}")"
toolchain_text="$(<"${RUST_TOOLCHAIN}")"
install_text="$(<"${INSTALL_SH}")"
setup_lib_text="$(<"${SETUP_LIB}")"
deny_text="$(<"${DENY_TOML}")"
linux_setup_text="$(<"${LINUX_SETUP}")"
install_spec_text="$(<"${INSTALL_SPEC}")"
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
assert_contains "$toolchain_text" 'components = ["clippy", "rustfmt"]' "repo rust-toolchain installs CI lint components"
assert_not_contains "$workflow_text" 'RUST_VERSION: "stable"' "release workflow does not use moving stable Rust"
assert_contains "$ci_text" 'CARGO_DENY_VERSION: "0.19.9"' "CI pins cargo-deny version"
assert_contains "$ci_text" "cargo install cargo-deny --version" "CI installs cargo-deny explicitly"
assert_contains "$ci_text" "cargo deny --manifest-path vibeguard-runtime/Cargo.toml --locked check -c deny.toml licenses bans sources" "CI enforces Rust dependency policy"
assert_before "$ci_text" "Validate Rust dependency policy" "Rust runtime checks" "CI validates dependency policy before runtime Cargo builds"
assert_contains "$ci_text" "cargo fmt --manifest-path vibeguard-runtime/Cargo.toml -- --check" "CI enforces Rust formatting"
assert_contains "$ci_text" "cargo clippy --manifest-path vibeguard-runtime/Cargo.toml --all-targets -- -D warnings" "CI treats Rust Clippy diagnostics as errors"
assert_contains "$deny_text" 'unknown-registry = "deny"' "deny.toml denies unknown registries"
assert_contains "$deny_text" 'unknown-git = "deny"' "deny.toml denies unknown git sources"
assert_contains "$deny_text" 'multiple-versions = "deny"' "deny.toml denies duplicate dependency versions"
assert_contains "$deny_text" '"MIT"' "deny.toml allows MIT license"
assert_contains "$deny_text" '"Apache-2.0"' "deny.toml allows Apache-2.0 license"
assert_contains "$deny_text" '"Unicode-3.0"' "deny.toml allows unicode-ident license"
assert_regex "$workflow_text" 'uses: actions/checkout@[0-9a-f]{40}[[:space:]]*# v6\.0\.2' "checkout action is pinned to a full commit SHA"
assert_regex "$workflow_text" 'uses: actions/upload-artifact@[0-9a-f]{40}[[:space:]]*# v7\.0\.1' "upload-artifact action is pinned to a full commit SHA"
assert_regex "$workflow_text" 'uses: actions/download-artifact@[0-9a-f]{40}[[:space:]]*# v8\.0\.1' "download-artifact action is pinned to a full commit SHA"
assert_regex "$workflow_text" 'uses: actions/attest-build-provenance@[0-9a-f]{40}[[:space:]]*# v4\.1\.0' "attestation action is pinned to a full commit SHA"
assert_contains "$workflow_text" "attestations: write" "build job can publish artifact attestations"
assert_contains "$workflow_text" "id-token: write" "build job can request OIDC token for attestations"
assert_contains "$workflow_text" "Attest runtime artifact" "release workflow attests runtime artifacts"
assert_contains "$workflow_text" "subject-path: dist/\${{ matrix.target }}/vibeguard-runtime-\${{ matrix.target }}" "release workflow attests each matrix runtime artifact"
assert_contains "$workflow_text" "sha256sum vibeguard-runtime-* | sort -k2 > SHA256SUMS" "checksums use deterministic sorted layout"
assert_contains "$workflow_text" "Attest checksum manifest" "release workflow attests checksum manifest"
assert_contains "$workflow_text" "subject-path: dist/SHA256SUMS" "release workflow attests SHA256SUMS"
assert_contains "$workflow_text" "Generate runtime release manifest" "release workflow generates runtime release manifest"
assert_contains "$workflow_text" "generate_runtime_release_manifest.py" "release workflow uses manifest generator"
assert_contains "$workflow_text" "dist/vibeguard-runtime-releases.json" "release workflow writes runtime release manifest asset"
assert_contains "$workflow_text" "Attest runtime release manifest" "release workflow attests runtime release manifest"
assert_contains "$workflow_text" "subject-path: dist/vibeguard-runtime-releases.json" "release workflow attests manifest path"
assert_contains "$workflow_text" "Generate dependency metadata" "release workflow generates dependency metadata"
assert_contains "$workflow_text" "cargo metadata --locked --manifest-path" "dependency metadata comes from locked Cargo graph"
assert_contains "$workflow_text" "vibeguard-runtime-dependency-metadata.json" "release publishes dependency metadata asset"
assert_contains "$workflow_text" 'GH_REPO: ${{ github.repository }}' "publish job pins gh target repository"
assert_contains "$setup_lib_text" "gh attestation verify" "setup verifies runtime release attestations when verifier is available"
assert_contains "$setup_lib_text" "--signer-workflow" "setup pins provenance signer workflow"
assert_contains "$setup_lib_text" '--source-ref "refs/tags/${tag}"' "setup pins provenance to the release tag"
assert_contains "$install_text" "provenance=verified-provenance" "install output reports verified provenance"
assert_contains "$install_text" "provenance=checksum-only" "install output reports checksum-only fallback explicitly"
assert_contains "$install_text" "--require-provenance" "install supports provenance-required mode"
assert_contains "$install_text" "provenance verification is required but unavailable" "install fails closed when strict provenance cannot verify"
assert_contains "$install_text" "cannot be combined with --build-from-source" "strict provenance rejects source-build mode"
assert_contains "$install_text" "runtime-provenance" "install snapshot records runtime provenance status"
assert_contains "$setup_lib_text" "vibeguard-runtime-releases.json" "setup knows runtime release manifest filename"
assert_contains "$install_text" "runtime release manifest checksum mismatch" "install fails closed on manifest checksum mismatch"
assert_contains "$install_text" "runtime release manifest verification failed" "install fails closed on malformed runtime release manifest"
assert_contains "$linux_setup_text" "--require-provenance" "Linux setup docs document strict provenance mode"
assert_contains "$linux_setup_text" "checksum-only" "Linux setup docs distinguish checksum-only mode"
assert_contains "$install_spec_text" "--require-provenance" "install spec documents strict provenance mode"
assert_contains "$install_spec_text" "release attestation verification passes" "install spec captures strict provenance acceptance criteria"

for target in \
  aarch64-apple-darwin \
  x86_64-apple-darwin \
  x86_64-unknown-linux-musl \
  aarch64-unknown-linux-musl
do
  assert_contains "$workflow_text" "target: ${target}" "release matrix includes ${target}"
done

header "runtime release manifest contract"
assert_cmd "runtime release manifest generator syntax is correct" python3 -m py_compile "${RELEASE_MANIFEST_SCRIPT}"
assert_cmd "runtime release manifest generator emits checked target metadata" bash -c '
  set -euo pipefail
  script="$1"
  tmp="$(mktemp -d)"
  trap "rm -rf \"${tmp}\"" EXIT
  sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum "$1" | awk "{print \$1}"
    else
      shasum -a 256 "$1" | awk "{print \$1}"
    fi
  }
  : > "${tmp}/SHA256SUMS"
  for target in \
    aarch64-apple-darwin \
    x86_64-apple-darwin \
    x86_64-unknown-linux-musl \
    aarch64-unknown-linux-musl
  do
    asset="${tmp}/vibeguard-runtime-${target}"
    printf "runtime asset %s\n" "${target}" > "${asset}"
    checksum="$(sha256_file "${asset}")"
    printf "%s  %s\n" "${checksum}" "vibeguard-runtime-${target}" >> "${tmp}/SHA256SUMS"
  done
  printf "{}\n" > "${tmp}/vibeguard-runtime-dependency-metadata.json"
  metadata_checksum="$(sha256_file "${tmp}/vibeguard-runtime-dependency-metadata.json")"
  printf "%s  vibeguard-runtime-dependency-metadata.json\n" "${metadata_checksum}" >> "${tmp}/SHA256SUMS"
  python3 "${script}" "9.9.9" "${tmp}" "${tmp}/vibeguard-runtime-releases.json" "majiayu000/vibeguard"
  python3 - "${tmp}/vibeguard-runtime-releases.json" "${tmp}" <<'"'"'PY'"'"'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
artifacts_dir = Path(sys.argv[2])
expected_targets = {
    "aarch64-apple-darwin",
    "x86_64-apple-darwin",
    "x86_64-unknown-linux-musl",
    "aarch64-unknown-linux-musl",
}
assert manifest["schema_version"] == 1
assert manifest["package"] == "vibeguard-runtime"
assert manifest["release_repo"] == "majiayu000/vibeguard"
assert manifest["version"] == "9.9.9"
assert manifest["tag"] == "v9.9.9"
assert set(manifest["assets"]) == expected_targets
for target, asset in manifest["assets"].items():
    assert asset["name"] == f"vibeguard-runtime-{target}"
    assert len(asset["sha256"]) == 64
    int(asset["sha256"], 16)
    assert asset["size"] == (artifacts_dir / asset["name"]).stat().st_size
PY
' _ "${RELEASE_MANIFEST_SCRIPT}"
assert_cmd "runtime release manifest generator rejects malformed SHA256SUMS rows" bash -c '
  set -euo pipefail
  script="$1"
  tmp="$(mktemp -d)"
  trap "rm -rf \"${tmp}\"" EXIT
  printf "not-a-valid-sha-row\n" > "${tmp}/SHA256SUMS"
  ! python3 "${script}" "9.9.9" "${tmp}" "${tmp}/vibeguard-runtime-releases.json" "majiayu000/vibeguard" 2>"${tmp}/err"
  grep -q "not a valid SHA256SUMS entry" "${tmp}/err"
' _ "${RELEASE_MANIFEST_SCRIPT}"
assert_cmd "runtime release manifest generator rejects unexpected runtime assets" bash -c '
  set -euo pipefail
  script="$1"
  tmp="$(mktemp -d)"
  trap "rm -rf \"${tmp}\"" EXIT
  checksum="0000000000000000000000000000000000000000000000000000000000000000"
  printf "%s  vibeguard-runtime-surprise-target\n" "${checksum}" > "${tmp}/SHA256SUMS"
  printf "unexpected runtime\n" > "${tmp}/vibeguard-runtime-surprise-target"
  ! python3 "${script}" "9.9.9" "${tmp}" "${tmp}/vibeguard-runtime-releases.json" "majiayu000/vibeguard" 2>"${tmp}/err"
  grep -q "unexpected runtime release asset" "${tmp}/err"
' _ "${RELEASE_MANIFEST_SCRIPT}"
assert_cmd "runtime release manifest generator rejects missing targets" bash -c '
  set -euo pipefail
  script="$1"
  tmp="$(mktemp -d)"
  trap "rm -rf \"${tmp}\"" EXIT
  sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum "$1" | awk "{print \$1}"
    else
      shasum -a 256 "$1" | awk "{print \$1}"
    fi
  }
  asset="${tmp}/vibeguard-runtime-aarch64-apple-darwin"
  printf "runtime asset\n" > "${asset}"
  checksum="$(sha256_file "${asset}")"
  printf "%s  vibeguard-runtime-aarch64-apple-darwin\n" "${checksum}" > "${tmp}/SHA256SUMS"
  ! python3 "${script}" "9.9.9" "${tmp}" "${tmp}/vibeguard-runtime-releases.json" "majiayu000/vibeguard"
' _ "${RELEASE_MANIFEST_SCRIPT}"

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

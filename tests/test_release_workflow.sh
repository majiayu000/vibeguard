#!/usr/bin/env bash
# Validate the runtime release workflow contract.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="${REPO_DIR}/.github/workflows/release.yml"
VERSION_FILE="${REPO_DIR}/vibeguard-runtime/VERSION"
CARGO_TOML="${REPO_DIR}/vibeguard-runtime/Cargo.toml"

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

workflow_text="$(<"${WORKFLOW}")"
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
assert_contains "$workflow_text" "sha256sum vibeguard-runtime-* | sort -k2 > SHA256SUMS" "checksums use deterministic sorted layout"
assert_contains "$workflow_text" 'GH_REPO: ${{ github.repository }}' "publish job pins gh target repository"

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

printf '\n==============================\n'
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' "$TOTAL" "$PASS" "$FAIL"
printf '==============================\n'

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi

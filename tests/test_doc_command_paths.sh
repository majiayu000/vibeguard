#!/usr/bin/env bash
# Focused regression tests for public documentation command validation.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATOR="${REPO_DIR}/scripts/ci/validate-doc-command-paths.sh"
PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }

assert_cmd() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc"
    FAIL=$((FAIL + 1))
  fi
}

assert_fails_with() {
  local desc="$1" expected="$2"
  shift 2
  TOTAL=$((TOTAL + 1))
  local output
  if output="$("$@" 2>&1)"; then
    red "$desc (expected failure)"
    FAIL=$((FAIL + 1))
  elif grep -qF -- "$expected" <<< "$output"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected output to contain: $expected)"
    printf '%s\n' "$output"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

new_fixture() {
  local name="$1"
  local root="${TMP_DIR}/${name}"
  mkdir -p "${root}/docs/how"
  printf '# README\n' > "${root}/README.md"
  printf '# Contributing\n' > "${root}/CONTRIBUTING.md"
  printf '# 中文\n' > "${root}/docs/README_CN.md"
  printf '%s\n' "${root}"
}

equals_fixture="$(new_fixture equals-form)"
printf '%s\n' 'curl -fsSL https://example.test/install.sh | bash -s -- --version=1.2.3' \
  >> "${equals_fixture}/README.md"
assert_fails_with "equals-form numeric release pin fails" \
  "README.md:2 hardcoded release version" \
  bash "${VALIDATOR}" "${equals_fixture}"

public_docs_fixture="$(new_fixture public-docs)"
printf '%s\n' 'curl -fsSL https://example.test/install.sh | bash -s -- --version 1.2.3' \
  > "${public_docs_fixture}/docs/how/quickstart.md"
assert_fails_with "numeric release pin in docs/how fails" \
  "docs/how/quickstart.md:1 hardcoded release version" \
  bash "${VALIDATOR}" "${public_docs_fixture}"

continued_fixture="$(new_fixture continued-command)"
cat > "${continued_fixture}/docs/how/quickstart.md" <<'MD'
curl -fsSL https://example.test/install.sh \
  | bash -s -- --version=1.2.3
MD
assert_fails_with "numeric release pin in a continued command fails" \
  "docs/how/quickstart.md:1 hardcoded release version" \
  bash "${VALIDATOR}" "${continued_fixture}"

placeholder_fixture="$(new_fixture placeholder)"
printf '%s\n' 'curl -fsSL https://example.test/install.sh | bash -s -- --version=X.Y.Z' \
  > "${placeholder_fixture}/docs/how/quickstart.md"
assert_cmd "placeholder release version passes" \
  bash "${VALIDATOR}" "${placeholder_fixture}"

printf '\nTotal: %d  Pass: %d  Fail: %d\n' "$TOTAL" "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi

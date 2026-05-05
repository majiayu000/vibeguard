#!/usr/bin/env bash
# VibeGuard prompt-contract regression tests
#
# Usage: bash tests/test_prompt_contract.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="${REPO_DIR}/scripts/lib/vibeguard_manifest.py"
SCHEMA="${REPO_DIR}/schemas/prompt-contract.schema.json"
REAL_AGENTS="${REPO_DIR}/templates/AGENTS.md"

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
    red "$desc (exit code: $?)"
    FAIL=$((FAIL + 1))
  fi
}

assert_cmd_fail() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    red "$desc (expected failure but command succeeded)"
    FAIL=$((FAIL + 1))
  else
    green "$desc"
    PASS=$((PASS + 1))
  fi
}

assert_stderr_contains() {
  local desc="$1"
  local expected="$2"
  shift 2
  TOTAL=$((TOTAL + 1))
  local stderr_output
  stderr_output="$("$@" 2>&1 >/dev/null || true)"
  if echo "$stderr_output" | grep -qF "$expected"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (stderr did not contain: $expected)"
    FAIL=$((FAIL + 1))
  fi
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

run_validator() {
  python3 "$HELPER" validate-prompt-contract --schema "$SCHEMA" "$@"
}

header "real templates/AGENTS.md"
assert_cmd "happy path on real AGENTS.md" \
  run_validator --target "$REAL_AGENTS"
assert_cmd "happy path on real AGENTS.md (strict)" \
  run_validator --target "$REAL_AGENTS" --strict

header "missing required section"
TARGET_MISSING="${WORK_DIR}/agents-no-verification.md"
sed '/^## Verification$/,/^## Routing$/{/^## Routing$/!d;}' "$REAL_AGENTS" > "$TARGET_MISSING"
assert_cmd_fail "missing Verification section -> error" \
  run_validator --target "$TARGET_MISSING"
assert_stderr_contains "missing Verification surfaces in stderr" \
  "missing required section: ## Verification" \
  run_validator --target "$TARGET_MISSING"

header "missing must-mention token"
TARGET_NOFORCE="${WORK_DIR}/agents-no-force-push.md"
sed 's/No force push/No rebase merge/' "$REAL_AGENTS" > "$TARGET_NOFORCE"
assert_cmd_fail "missing 'force push' token -> error" \
  run_validator --target "$TARGET_NOFORCE"
assert_stderr_contains "missing force-push surfaces in stderr" \
  "missing required mention: 'force push'" \
  run_validator --target "$TARGET_NOFORCE"

header "unknown section heading"
TARGET_EXTRA="${WORK_DIR}/agents-extra-section.md"
{
  cat "$REAL_AGENTS"
  printf '\n## Random Extra Section\n\nplaceholder body\n'
} > "$TARGET_EXTRA"
assert_cmd "unknown heading is warning, not error (default)" \
  run_validator --target "$TARGET_EXTRA"
assert_stderr_contains "unknown heading surfaces as WARN" \
  "WARN: unknown section heading: ## Random Extra Section" \
  run_validator --target "$TARGET_EXTRA"

header "ancestor directory named 'agents' must not misclassify root AGENTS"
ANCESTOR_DIR="${WORK_DIR}/agents/myrepo-clone/templates"
mkdir -p "$ANCESTOR_DIR"
ANCESTOR_TARGET="${ANCESTOR_DIR}/AGENTS.md"
cp "$REAL_AGENTS" "$ANCESTOR_TARGET"
assert_cmd "checkout under ancestor 'agents/' still treats AGENTS.md as root" \
  run_validator --target "$ANCESTOR_TARGET"

header "relative path under agents/ is treated as role prompt"
RELATIVE_OUTPUT="$(cd "$REPO_DIR" && python3 "$HELPER" validate-prompt-contract \
  --schema "$SCHEMA" --target agents/architect.md 2>&1 || true)"
TOTAL=$((TOTAL + 1))
if echo "$RELATIVE_OUTPUT" | grep -qF "missing required section"; then
  red "relative agents/architect.md must skip required-section check"
  FAIL=$((FAIL + 1))
else
  green "relative agents/architect.md skips required-section check"
  PASS=$((PASS + 1))
fi

header "role prompt frontmatter"
ROLE_DIR="${WORK_DIR}/agents"
mkdir -p "$ROLE_DIR"
GOOD_ROLE="${ROLE_DIR}/good.md"
cat > "$GOOD_ROLE" <<'ROLE'
---
name: example-agent
description: example role for tests
model: sonnet
tools: Read, Grep, Glob
---

## Operating Principles

- No force push.
- No secrets in commits.
- No AI marker tags.

## Routing

Route work to the right specialist.

## Verification

Run the project's standard verification before claiming completion.

## Chat Contract

Concise updates by default.
ROLE

assert_cmd "role prompt with all 4 frontmatter keys passes" \
  run_validator --target "$GOOD_ROLE"

BAD_ROLE="${ROLE_DIR}/missing-model.md"
sed '/^model:/d' "$GOOD_ROLE" > "$BAD_ROLE"
assert_cmd_fail "role prompt missing model key -> error" \
  run_validator --target "$BAD_ROLE"
assert_stderr_contains "missing-model surfaces in stderr" \
  "role prompt missing frontmatter key: model" \
  run_validator --target "$BAD_ROLE"

header "line budget"
LARGE_TARGET="${WORK_DIR}/agents-too-large.md"
{
  cat "$REAL_AGENTS"
  printf '\n## Code Style\n\n'
  for _ in $(seq 1 310); do
    printf -- '- filler line for budget testing\n'
  done
} > "$LARGE_TARGET"
assert_cmd "exceeds max budget without --strict -> warning only" \
  run_validator --target "$LARGE_TARGET"
assert_cmd_fail "exceeds max budget under --strict -> error" \
  run_validator --target "$LARGE_TARGET" --strict

header "summary"
echo
echo "=============================="
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

exit $((FAIL > 0 ? 1 : 0))

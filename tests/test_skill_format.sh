#!/usr/bin/env bash
# VibeGuard skill format validation regression tests

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATOR="${REPO_DIR}/scripts/ci/validate-skill-format.py"

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

assert_contains() {
  local output="$1" expected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$output" | grep -qF -- "$expected"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected to contain: $expected)"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

write_valid_skill() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'MD'
---
name: demo-skill
description: Use when validating VibeGuard skill format structure.
---

# Demo Skill

## When to Activate

- User asks for the demo skill.

## Red Flags

- **Missing source search** - new behavior is proposed without checking existing files.
- **No verification** - the skill describes work but never proves it.
- **Generic warning** - the red flag does not name a concrete failure mode.

## Checklist

- [ ] Search existing skills before creating a new one.
- [ ] Confirm the activation cue matches the task.
- [ ] Run focused verification before handoff.
MD
}

header "syntax"
assert_cmd "validate-skill-format.py syntax is valid" python3 -m py_compile "${VALIDATOR}"

header "repository coverage"
assert_cmd "repository skills and workflows pass format validation" \
  bash "${REPO_DIR}/scripts/ci/validate-skill-format.sh"

header "single-file validation"
VALID_SKILL="${TMP_DIR}/skills/demo/SKILL.md"
write_valid_skill "${VALID_SKILL}"
assert_cmd "valid skill passes" python3 "${VALIDATOR}" "${VALID_SKILL}"

header "missing required section"
MISSING_RED_FLAGS="${TMP_DIR}/missing-red-flags/SKILL.md"
write_valid_skill "${MISSING_RED_FLAGS}"
perl -0pi -e 's/\n## Red Flags\n.*?\n## Checklist/\n## Checklist/s' "${MISSING_RED_FLAGS}"
missing_out="$(python3 "${VALIDATOR}" "${MISSING_RED_FLAGS}" 2>&1 || true)"
assert_contains "${missing_out}" "missing ## Red Flags section" "missing red flags section fails"

header "empty required lists"
EMPTY_RED_FLAGS="${TMP_DIR}/empty-red-flags/SKILL.md"
write_valid_skill "${EMPTY_RED_FLAGS}"
perl -0pi -e 's/## Red Flags\n\n.*?\n## Checklist/## Red Flags\n\nNo bullets here.\n\n## Checklist/s' "${EMPTY_RED_FLAGS}"
empty_red_out="$(python3 "${VALIDATOR}" "${EMPTY_RED_FLAGS}" 2>&1 || true)"
assert_contains "${empty_red_out}" "## Red Flags must contain at least 3 bullets" "empty red flags list fails"

EMPTY_CHECKLIST="${TMP_DIR}/empty-checklist/SKILL.md"
write_valid_skill "${EMPTY_CHECKLIST}"
perl -0pi -e 's/## Checklist\n\n.*\z/## Checklist\n\nNo checkbox items here.\n/s' "${EMPTY_CHECKLIST}"
empty_checklist_out="$(python3 "${VALIDATOR}" "${EMPTY_CHECKLIST}" 2>&1 || true)"
assert_contains "${empty_checklist_out}" "## Checklist must contain at least 3 checkbox items" "empty checklist fails"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

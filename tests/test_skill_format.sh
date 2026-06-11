#!/usr/bin/env bash
# VibeGuard skill format validation regression tests

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATOR="${REPO_DIR}/scripts/ci/validate-skill-format.py"
SKILL_VALIDATE="${REPO_DIR}/scripts/skill_validate.py"
SHARED_VALIDATOR="${REPO_DIR}/scripts/lib/skill_format.py"

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
assert_cmd "skill_format.py syntax is valid" python3 -m py_compile "${SHARED_VALIDATOR}"

header "repository coverage"
assert_cmd "repository skills, workflows, and template pass format validation" \
  bash "${REPO_DIR}/scripts/ci/validate-skill-format.sh"
repo_format_out="$(python3 "${VALIDATOR}" --repo-dir "${REPO_DIR}")"
assert_contains "${repo_format_out}" "templates/skill-template.md" "repository format coverage includes skill template"
assert_contains "${repo_format_out}" ".claude/skills/benchmark-regression-triage/SKILL.md" "repository format coverage includes repo-local Claude skill"
assert_cmd "skill template passes direct format validation" \
  python3 "${VALIDATOR}" "${REPO_DIR}/templates/skill-template.md"

header "single-file validation"
VALID_SKILL="${TMP_DIR}/skills/demo/SKILL.md"
write_valid_skill "${VALID_SKILL}"
assert_cmd "valid skill passes" python3 "${VALIDATOR}" "${VALID_SKILL}"
assert_cmd "valid skill passes skill_validate format gate" \
  python3 "${SKILL_VALIDATE}" --format-only --proposed-skill "${VALID_SKILL}"

header "missing required section"
MISSING_RED_FLAGS="${TMP_DIR}/missing-red-flags/SKILL.md"
write_valid_skill "${MISSING_RED_FLAGS}"
perl -0pi -e 's/\n## Red Flags\n.*?\n## Checklist/\n## Checklist/s' "${MISSING_RED_FLAGS}"
missing_out="$(python3 "${VALIDATOR}" "${MISSING_RED_FLAGS}" 2>&1 || true)"
assert_contains "${missing_out}" "missing required section: ## Red Flags" "missing red flags section fails"

header "empty required lists"
EMPTY_RED_FLAGS="${TMP_DIR}/empty-red-flags/SKILL.md"
write_valid_skill "${EMPTY_RED_FLAGS}"
perl -0pi -e 's/## Red Flags\n\n.*?\n## Checklist/## Red Flags\n\nNo bullets here.\n\n## Checklist/s' "${EMPTY_RED_FLAGS}"
empty_red_out="$(python3 "${VALIDATOR}" "${EMPTY_RED_FLAGS}" 2>&1 || true)"
assert_contains "${empty_red_out}" "## Red Flags has no useful list items" "empty red flags list fails"

EMPTY_CHECKLIST="${TMP_DIR}/empty-checklist/SKILL.md"
write_valid_skill "${EMPTY_CHECKLIST}"
perl -0pi -e 's/## Checklist\n\n.*\z/## Checklist\n\nNo checkbox items here.\n/s' "${EMPTY_CHECKLIST}"
empty_checklist_out="$(python3 "${VALIDATOR}" "${EMPTY_CHECKLIST}" 2>&1 || true)"
assert_contains "${empty_checklist_out}" "## Checklist has no useful list items" "empty checklist fails"

header "shared rule source"
DRIFT_SKILL="${TMP_DIR}/drift/SKILL.md"
write_valid_skill "${DRIFT_SKILL}"
perl -0pi -e 's/## Red Flags\n\n.*?\n## Checklist/## Red Flags\n\n- Only one red flag.\n\n## Checklist/s' "${DRIFT_SKILL}"
perl -0pi -e 's/## Checklist\n\n.*\z/## Checklist\n\n- [ ] Only one checklist item.\n/s' "${DRIFT_SKILL}"
drift_ci_out="$(python3 "${VALIDATOR}" "${DRIFT_SKILL}" 2>&1 || true)"
drift_skill_validate_out="$(
  python3 "${SKILL_VALIDATE}" --format-only --proposed-skill "${DRIFT_SKILL}" 2>&1 || true
)"
assert_contains "${drift_ci_out}" "## Red Flags must contain at least 3 bullets" "CI validator rejects underfilled red flags"
assert_contains "${drift_ci_out}" "## Checklist must contain at least 3 checkbox items" "CI validator rejects underfilled checklist"
assert_contains "${drift_skill_validate_out}" "## Red Flags must contain at least 3 bullets" "skill_validate rejects underfilled red flags"
assert_contains "${drift_skill_validate_out}" "## Checklist must contain at least 3 checkbox items" "skill_validate rejects underfilled checklist"

NO_FRONTMATTER_SKILL="${TMP_DIR}/no-frontmatter/SKILL.md"
write_valid_skill "${NO_FRONTMATTER_SKILL}"
perl -0pi -e 's/^---\nname: demo-skill\ndescription: Use when validating VibeGuard skill format structure\.\n---\n//' "${NO_FRONTMATTER_SKILL}"
frontmatter_ci_out="$(python3 "${VALIDATOR}" "${NO_FRONTMATTER_SKILL}" 2>&1 || true)"
frontmatter_skill_validate_out="$(
  python3 "${SKILL_VALIDATE}" --format-only --proposed-skill "${NO_FRONTMATTER_SKILL}" 2>&1 || true
)"
assert_contains "${frontmatter_ci_out}" "missing YAML frontmatter opening" "CI validator rejects missing frontmatter"
assert_contains "${frontmatter_skill_validate_out}" "missing YAML frontmatter opening" "skill_validate rejects missing frontmatter"

header "frontmatter delimiter"
BLOCK_SCALAR_SKILL="${TMP_DIR}/block-scalar/SKILL.md"
write_valid_skill "${BLOCK_SCALAR_SKILL}"
perl -0pi -e 's/description: Use when validating VibeGuard skill format structure\./description: |\n  Use when validating VibeGuard skill format structure.\n  Covers multiline descriptions./' "${BLOCK_SCALAR_SKILL}"
assert_cmd "valid block scalar frontmatter passes" python3 "${VALIDATOR}" "${BLOCK_SCALAR_SKILL}"

NUMERIC_BLOCK_SCALAR_SKILL="${TMP_DIR}/numeric-block-scalar/SKILL.md"
write_valid_skill "${NUMERIC_BLOCK_SCALAR_SKILL}"
perl -0pi -e 's/description: Use when validating VibeGuard skill format structure\./description: |2\n  Use when validating VibeGuard skill format structure.\n  Numeric block scalar indentation indicator./' "${NUMERIC_BLOCK_SCALAR_SKILL}"
assert_cmd "block scalar with numeric indentation indicator passes" python3 "${VALIDATOR}" "${NUMERIC_BLOCK_SCALAR_SKILL}"

CHOMPING_FIRST_BLOCK_SCALAR_SKILL="${TMP_DIR}/chomping-first-block-scalar/SKILL.md"
write_valid_skill "${CHOMPING_FIRST_BLOCK_SCALAR_SKILL}"
perl -0pi -e 's/description: Use when validating VibeGuard skill format structure\./description: |-2\n  Use when validating VibeGuard skill format structure.\n  Chomping indicator before numeric indentation indicator./' "${CHOMPING_FIRST_BLOCK_SCALAR_SKILL}"
assert_cmd "block scalar with chomping-before-indent indicator passes" python3 "${VALIDATOR}" "${CHOMPING_FIRST_BLOCK_SCALAR_SKILL}"

FOLDED_CHOMPING_FIRST_BLOCK_SCALAR_SKILL="${TMP_DIR}/folded-chomping-first-block-scalar/SKILL.md"
write_valid_skill "${FOLDED_CHOMPING_FIRST_BLOCK_SCALAR_SKILL}"
perl -0pi -e 's/description: Use when validating VibeGuard skill format structure\./description: >+2\n  Use when validating VibeGuard skill format structure.\n  Folded scalar with chomping before indentation indicator./' "${FOLDED_CHOMPING_FIRST_BLOCK_SCALAR_SKILL}"
assert_cmd "folded block scalar with chomping-before-indent indicator passes" python3 "${VALIDATOR}" "${FOLDED_CHOMPING_FIRST_BLOCK_SCALAR_SKILL}"

INDENTED_BODY_SKILL="${TMP_DIR}/indented-body/SKILL.md"
write_valid_skill "${INDENTED_BODY_SKILL}"
perl -0pi -e 's/description: Use when validating VibeGuard skill format structure\./description: Use when validating VibeGuard skill format structure.\n  This indented body text is not a YAML block scalar./' "${INDENTED_BODY_SKILL}"
indented_body_out="$(python3 "${VALIDATOR}" "${INDENTED_BODY_SKILL}" 2>&1 || true)"
assert_contains "${indented_body_out}" "invalid indented frontmatter line before closing delimiter" "indented non-YAML frontmatter content fails"

MISSING_CLOSING_WITH_BODY_RULE="${TMP_DIR}/missing-closing-body-rule/SKILL.md"
write_valid_skill "${MISSING_CLOSING_WITH_BODY_RULE}"
perl -0pi -e 's/^---\nname: demo-skill\ndescription: Use when validating VibeGuard skill format structure\.\n---\n/---\nname: demo-skill\ndescription: Use when validating VibeGuard skill format structure.\n/s' "${MISSING_CLOSING_WITH_BODY_RULE}"
perl -0pi -e 's/\n## When to Activate/\n---\n\n## When to Activate/s' "${MISSING_CLOSING_WITH_BODY_RULE}"
missing_closing_body_out="$(python3 "${VALIDATOR}" "${MISSING_CLOSING_WITH_BODY_RULE}" 2>&1 || true)"
assert_contains "${missing_closing_body_out}" "invalid frontmatter line before closing delimiter" "body delimiter does not hide missing frontmatter closing"

INDENTED_BODY_BEFORE_CLOSE="${TMP_DIR}/indented-body-before-close/SKILL.md"
write_valid_skill "${INDENTED_BODY_BEFORE_CLOSE}"
perl -0pi -e 's/^---\nname: demo-skill\ndescription: Use when validating VibeGuard skill format structure\.\n---\n/---\nname: demo-skill\ndescription: Use when validating VibeGuard skill format structure.\n  This body line is not YAML frontmatter.\n---\n/s' "${INDENTED_BODY_BEFORE_CLOSE}"
indented_body_out="$(python3 "${VALIDATOR}" "${INDENTED_BODY_BEFORE_CLOSE}" 2>&1 || true)"
assert_contains "${indented_body_out}" "invalid indented frontmatter line before closing delimiter" "indented non-YAML before close fails"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

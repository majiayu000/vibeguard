#!/usr/bin/env bash
# VibeGuard skill validation regression tests

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_VALIDATE="${REPO_DIR}/scripts/skill_validate.py"

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

SKILL_DIR="${TMP_DIR}/demo-skill"
mkdir -p "${SKILL_DIR}"
cat > "${SKILL_DIR}/SKILL.md" <<'MD'
---
name: demo-skill
description: Use when validating a proposed skill change.
---

# Demo Skill

## When to Activate

- Validate a proposed VibeGuard skill before adoption.

## Red Flags

- The proposed skill has no repeatable trigger condition.

## Checklist

- Confirm the skill has repair evidence and no unrelated regressions.
MD

header "syntax"
assert_cmd "skill_validate.py syntax is valid" python3 -m py_compile "${SKILL_VALIDATE}"

header "format gate"
assert_cmd "format-only accepts shaped skill" \
  python3 "${SKILL_VALIDATE}" --format-only --proposed-skill "${SKILL_DIR}/SKILL.md"
assert_cmd "format-only accepts repository skill template" \
  python3 "${SKILL_VALIDATE}" --format-only --proposed-skill "${REPO_DIR}/templates/skill-template.md" --no-persist

MARKDOWN_LINK_DIR="${TMP_DIR}/markdown-link"
mkdir -p "${MARKDOWN_LINK_DIR}"
cat > "${MARKDOWN_LINK_DIR}/SKILL.md" <<'MD'
---
name: markdown-link
description: Use when testing Markdown link list items.
---

# Markdown Link

## When to Activate

- Validate a draft skill that links to shared contracts.

## Red Flags

- [Routing Contract](../references/routing-contract.md) is not reflected in the skill handoff.

## Checklist

- [Delivery Base](../references/delivery-base.md) was reviewed before final verification.
MD
assert_cmd "format-only accepts Markdown-link list items" \
  python3 "${SKILL_VALIDATE}" --format-only --proposed-skill "${MARKDOWN_LINK_DIR}/SKILL.md"

MISSING_SECTION_DIR="${TMP_DIR}/missing-section"
mkdir -p "${MISSING_SECTION_DIR}"
cat > "${MISSING_SECTION_DIR}/SKILL.md" <<'MD'
---
name: missing-section
description: Use when testing missing sections.
---

# Missing Section

## Red Flags

- A required heading is absent.

## Checklist

- Detect the missing heading.
MD
missing_section_out="$(
  python3 "${SKILL_VALIDATE}" \
    --format-only \
    --proposed-skill "${MISSING_SECTION_DIR}/SKILL.md" 2>&1 || true
)"
assert_contains "${missing_section_out}" "missing required section: ## When to Activate" "format gate reports missing activation section"

EMPTY_LIST_DIR="${TMP_DIR}/empty-list"
mkdir -p "${EMPTY_LIST_DIR}"
cat > "${EMPTY_LIST_DIR}/SKILL.md" <<'MD'
---
name: empty-list
description: Use when testing empty Red Flags and Checklist sections.
---

# Empty List

## When to Activate

- Validate a draft skill.

## Red Flags

This section has prose but no list item.

## Checklist

- [Checklist item]
MD
empty_list_out="$(
  python3 "${SKILL_VALIDATE}" \
    --format-only \
    --proposed-skill "${EMPTY_LIST_DIR}/SKILL.md" 2>&1 || true
)"
assert_contains "${empty_list_out}" "## Red Flags has no useful list items" "format gate rejects Red Flags without list items"
assert_contains "${empty_list_out}" "## Checklist has no useful list items" "format gate rejects placeholder Checklist items"

COVERAGE_REPO="${TMP_DIR}/coverage-repo"
mkdir -p "${COVERAGE_REPO}/skills/good" "${COVERAGE_REPO}/workflows/bad"
cp "${SKILL_DIR}/SKILL.md" "${COVERAGE_REPO}/skills/good/SKILL.md"
cat > "${COVERAGE_REPO}/workflows/bad/SKILL.md" <<'MD'
---
name: bad-workflow
description: Use when testing workflow coverage.
---

# Bad Workflow

## When to Activate

- Validate workflow skill coverage.

## Red Flags

- The repository check ignores workflow skills.
MD
coverage_out="$(
  python3 "${SKILL_VALIDATE}" \
    --check-repo-format \
    --repo-root "${COVERAGE_REPO}" 2>&1 || true
)"
assert_contains "${coverage_out}" "workflows/bad/SKILL.md: missing required section: ## Checklist" "repo format gate covers workflows"

TEMPLATE_COVERAGE_REPO="${TMP_DIR}/template-coverage-repo"
mkdir -p "${TEMPLATE_COVERAGE_REPO}/templates"
cat > "${TEMPLATE_COVERAGE_REPO}/templates/skill-template.md" <<'MD'
---
name: bad-template
description: Use when testing template coverage.
---

# Bad Template

## When to Activate

- Validate template coverage.
MD
template_coverage_out="$(
  python3 "${SKILL_VALIDATE}" \
    --check-repo-format \
    --repo-root "${TEMPLATE_COVERAGE_REPO}" 2>&1 || true
)"
assert_contains "${template_coverage_out}" "templates/skill-template.md: missing required section: ## Red Flags" "repo format gate covers skill template"

assert_cmd "repo skill, workflow, and template format gate passes" \
  python3 "${SKILL_VALIDATE}" --check-repo-format --repo-root "${REPO_DIR}"

header "passing repair evidence"
PASSING_JSONL="${TMP_DIR}/passing.jsonl"
cat > "${PASSING_JSONL}" <<'JSONL'
{"scenario_id":"incident-1","scenario_type":"target","without_skill":{"outcome":"failure"},"with_skill":{"outcome":"success"},"scored_against_agent":"claude-opus-4-7","scored_at":"2026-05-18"}
{"scenario_id":"unrelated-1","scenario_type":"unrelated","without_skill":{"outcome":"success"},"with_skill":{"outcome":"success"},"scored_against_agent":"claude-opus-4-7","scored_at":"2026-05-18"}
{"scenario_id":"unrelated-2","scenario_type":"unrelated","without_skill":{"outcome":"success"},"with_skill":{"outcome":"success"},"scored_against_agent":"claude-opus-4-7","scored_at":"2026-05-18"}
JSONL
passing_out="$(
  python3 "${SKILL_VALIDATE}" \
    --proposed-skill "${SKILL_DIR}/SKILL.md" \
    --baseline-trajectories "${PASSING_JSONL}" \
    --output-dir "${TMP_DIR}/artifacts" \
    --current-agent claude-opus-4-7 \
    --as-of 2026-05-18
)"
assert_contains "${passing_out}" "verdict: pass" "pass verdict when repair beats regression"
assert_contains "${passing_out}" "repair: 1" "pass output records repair count"
assert_cmd "pass verdict writes an artifact" test -f "${TMP_DIR}/artifacts/demo-skill-2026-05-18.jsonl"

header "unrelated evidence is required"
NO_UNRELATED_JSONL="${TMP_DIR}/no-unrelated.jsonl"
cat > "${NO_UNRELATED_JSONL}" <<'JSONL'
{"scenario_id":"incident-1","scenario_type":"target","without_skill":{"outcome":"failure"},"with_skill":{"outcome":"success"},"scored_against_agent":"claude-opus-4-7","scored_at":"2026-05-18"}
JSONL
no_unrelated_out="$(
  python3 "${SKILL_VALIDATE}" \
    --proposed-skill "${SKILL_DIR}/SKILL.md" \
    --baseline-trajectories "${NO_UNRELATED_JSONL}" \
    --no-persist \
    --current-agent claude-opus-4-7 \
    --as-of 2026-05-18 2>&1 || true
)"
assert_contains "${no_unrelated_out}" "verdict: fail" "missing unrelated scenarios fails verdict"
assert_contains "${no_unrelated_out}" "fewer than two unrelated no-change scenarios" "missing unrelated scenarios explains requirement"

header "regression needs justification"
REGRESSION_JSONL="${TMP_DIR}/regression.jsonl"
cat > "${REGRESSION_JSONL}" <<'JSONL'
{"scenario_id":"incident-1","scenario_type":"target","without_skill":{"outcome":"failure"},"with_skill":{"outcome":"success"},"scored_against_agent":"claude-opus-4-7","scored_at":"2026-05-18"}
{"scenario_id":"incident-2","scenario_type":"target","without_skill":{"outcome":"failure"},"with_skill":{"outcome":"success"},"scored_against_agent":"claude-opus-4-7","scored_at":"2026-05-18"}
{"scenario_id":"adjacent-1","scenario_type":"target","without_skill":{"outcome":"success"},"with_skill":{"outcome":"failure"},"scored_against_agent":"claude-opus-4-7","scored_at":"2026-05-18"}
{"scenario_id":"unrelated-1","scenario_type":"unrelated","without_skill":{"outcome":"success"},"with_skill":{"outcome":"success"},"scored_against_agent":"claude-opus-4-7","scored_at":"2026-05-18"}
{"scenario_id":"unrelated-2","scenario_type":"unrelated","without_skill":{"outcome":"success"},"with_skill":{"outcome":"success"},"scored_against_agent":"claude-opus-4-7","scored_at":"2026-05-18"}
JSONL
regression_out="$(
  python3 "${SKILL_VALIDATE}" \
    --proposed-skill "${SKILL_DIR}/SKILL.md" \
    --baseline-trajectories "${REGRESSION_JSONL}" \
    --no-persist \
    --current-agent claude-opus-4-7 \
    --as-of 2026-05-18 2>&1 || true
)"
assert_contains "${regression_out}" "verdict: needs_justification" "regression without justification blocks acceptance"
assert_contains "${regression_out}" "regression: 1" "regression output records regression count"

header "unrelated regression becomes advisory"
UNRELATED_JSONL="${TMP_DIR}/unrelated.jsonl"
cat > "${UNRELATED_JSONL}" <<'JSONL'
{"scenario_id":"incident-1","scenario_type":"target","without_skill":{"outcome":"failure"},"with_skill":{"outcome":"success"},"scored_against_agent":"claude-opus-4-7","scored_at":"2026-05-18"}
{"scenario_id":"incident-2","scenario_type":"target","without_skill":{"outcome":"failure"},"with_skill":{"outcome":"success"},"scored_against_agent":"claude-opus-4-7","scored_at":"2026-05-18"}
{"scenario_id":"unrelated-1","scenario_type":"unrelated","without_skill":{"outcome":"success"},"with_skill":{"outcome":"failure"},"scored_against_agent":"claude-opus-4-7","scored_at":"2026-05-18"}
{"scenario_id":"unrelated-2","scenario_type":"unrelated","without_skill":{"outcome":"success"},"with_skill":{"outcome":"success"},"scored_against_agent":"claude-opus-4-7","scored_at":"2026-05-18"}
{"scenario_id":"unrelated-3","scenario_type":"unrelated","without_skill":{"outcome":"success"},"with_skill":{"outcome":"success"},"scored_against_agent":"claude-opus-4-7","scored_at":"2026-05-18"}
JSONL
unrelated_out="$(
  python3 "${SKILL_VALIDATE}" \
    --proposed-skill "${SKILL_DIR}/SKILL.md" \
    --baseline-trajectories "${UNRELATED_JSONL}" \
    --no-persist \
    --current-agent claude-opus-4-7 \
    --regression-justification "target repair is worth advisory rollout" \
    --as-of 2026-05-18 2>&1 || true
)"
assert_contains "${unrelated_out}" "verdict: advisory" "unrelated regression downgrades the skill"
assert_contains "${unrelated_out}" "unrelated_regression: 1" "unrelated regression count is explicit"

header "stale evidence blocks verdict"
STALE_JSONL="${TMP_DIR}/stale.jsonl"
cat > "${STALE_JSONL}" <<'JSONL'
{"scenario_id":"incident-1","scenario_type":"target","without_skill":{"outcome":"failure"},"with_skill":{"outcome":"success"},"scored_against_agent":"older-agent","scored_at":"2026-01-01"}
JSONL
stale_out="$(
  python3 "${SKILL_VALIDATE}" \
    --proposed-skill "${SKILL_DIR}/SKILL.md" \
    --baseline-trajectories "${STALE_JSONL}" \
    --no-persist \
    --current-agent claude-opus-4-7 \
    --as-of 2026-05-18 2>&1 || true
)"
assert_contains "${stale_out}" "verdict: stale" "stale evidence blocks acceptance"
assert_contains "${stale_out}" "scored against older-agent, not claude-opus-4-7" "stale output names agent mismatch"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

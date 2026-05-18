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
MD

header "syntax"
assert_cmd "skill_validate.py syntax is valid" python3 -m py_compile "${SKILL_VALIDATE}"

header "passing repair evidence"
PASSING_JSONL="${TMP_DIR}/passing.jsonl"
cat > "${PASSING_JSONL}" <<'JSONL'
{"scenario_id":"incident-1","scenario_type":"target","without_skill":{"outcome":"failure"},"with_skill":{"outcome":"success"},"scored_against_agent":"claude-opus-4-7","scored_at":"2026-05-18"}
{"scenario_id":"unrelated-1","scenario_type":"unrelated","without_skill":{"outcome":"success"},"with_skill":{"outcome":"success"},"scored_against_agent":"claude-opus-4-7","scored_at":"2026-05-18"}
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

header "regression needs justification"
REGRESSION_JSONL="${TMP_DIR}/regression.jsonl"
cat > "${REGRESSION_JSONL}" <<'JSONL'
{"scenario_id":"incident-1","scenario_type":"target","without_skill":{"outcome":"failure"},"with_skill":{"outcome":"success"},"scored_against_agent":"claude-opus-4-7","scored_at":"2026-05-18"}
{"scenario_id":"incident-2","scenario_type":"target","without_skill":{"outcome":"failure"},"with_skill":{"outcome":"success"},"scored_against_agent":"claude-opus-4-7","scored_at":"2026-05-18"}
{"scenario_id":"adjacent-1","scenario_type":"target","without_skill":{"outcome":"success"},"with_skill":{"outcome":"failure"},"scored_against_agent":"claude-opus-4-7","scored_at":"2026-05-18"}
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

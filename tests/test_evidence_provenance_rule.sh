#!/usr/bin/env bash
# GH-687: W-21 evidence-provenance rule contract and W-01 step 0 contract.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

RULE_FILE="rules/claude-rules/common/evidence-provenance.md"
WORKFLOW_RULE="rules/claude-rules/common/workflow.md"
GENERATED_UNIVERSAL="rules/universal.md"

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header(){ printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

assert_file_matches() {
  local file="$1" pattern="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if grep -Eq "$pattern" "$file"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected ${file} to match: ${pattern})"
    FAIL=$((FAIL + 1))
  fi
}

header "B-001 canonical rule source"
assert_file_matches "$RULE_FILE" \
  '^## W-21: Evidence must be provably executed, not merely cited \(strict\)$' \
  "W-21 heading declares strict severity"
assert_file_matches "$RULE_FILE" \
  '^\*\*Compact guidance:\*\* .+' \
  "W-21 carries a compact guidance line"

header "B-002 out-of-session channels"
assert_file_matches "$RULE_FILE" 'Out-of-session channels' \
  "W-21 defines out-of-session channels"
for channel in 'transcript' 'Filesystem' 'Git' 'Exit codes'; do
  assert_file_matches "$RULE_FILE" "$channel" \
    "W-21 names the ${channel} channel"
done

header "B-003 single-value signals over text recall"
assert_file_matches "$RULE_FILE" \
  'single-value signals persisted to disk' \
  "W-21 prefers persisted single-value signals"
assert_file_matches "$RULE_FILE" \
  'Fabrication risk grows with output length' \
  "W-21 explains why long output is weaker evidence"

header "B-004 accusing the environment is a red flag"
assert_file_matches "$RULE_FILE" \
  'Accusing the environment is a red flag' \
  "W-21 flags harness/hook accusations"
assert_file_matches "$RULE_FILE" \
  'never instruct a user to disable a hook' \
  "W-21 blocks hook-disabling advice without out-of-session proof"

header "B-005 session kill criterion"
assert_file_matches "$RULE_FILE" \
  'Session kill criterion' \
  "W-21 defines a session kill criterion"
assert_file_matches "$RULE_FILE" \
  'falsified \*\*2 times\*\*' \
  "W-21 sets the kill threshold at 2 falsified theories"
assert_file_matches "$RULE_FILE" \
  'Recover state from disk artifacts' \
  "W-21 requires recovery from disk artifacts"

header "B-006 W-01 step 0"
assert_file_matches "$WORKFLOW_RULE" \
  '^0\. \*\*Channel trust check\*\*' \
  "W-01 protocol starts at step 0"
assert_file_matches "$WORKFLOW_RULE" \
  'my own reading or context is degraded' \
  "W-01 step 0 names self-degradation as the first hypothesis"
assert_file_matches "$WORKFLOW_RULE" \
  '^1\. \*\*Root-cause investigation\*\*' \
  "W-01 keeps the original root-cause investigation phase"
assert_file_matches "$WORKFLOW_RULE" \
  'W-21' \
  "W-01 cross-references W-21"

header "B-007 rule ID uniqueness"
TOTAL=$((TOTAL + 1))
w21_definitions="$(grep -rc '^## W-21:' rules/claude-rules/ 2>/dev/null \
  | awk -F: '{ sum += $2 } END { print sum + 0 }')"
if [[ "$w21_definitions" == "1" ]]; then
  green "W-21 is defined exactly once in the canonical source"
  PASS=$((PASS + 1))
else
  red "W-21 must be defined exactly once (found: ${w21_definitions})"
  FAIL=$((FAIL + 1))
fi

TOTAL=$((TOTAL + 1))
if grep -Eq '^\| W-20 \| Long tasks must pin runtime' "$GENERATED_UNIVERSAL"; then
  green "W-20 still belongs to the execution-pinning rule (no ID collision)"
  PASS=$((PASS + 1))
else
  red "W-20 must remain the execution-pinning rule in ${GENERATED_UNIVERSAL}"
  FAIL=$((FAIL + 1))
fi

header "B-008 generated docs are in sync"
TOTAL=$((TOTAL + 1))
if python3 scripts/generate_rule_docs.py --check >/dev/null 2>&1; then
  green "generated rule docs match the canonical source"
  PASS=$((PASS + 1))
else
  red "generated rule docs are stale (run: python3 scripts/generate_rule_docs.py)"
  FAIL=$((FAIL + 1))
fi

assert_file_matches "$GENERATED_UNIVERSAL" \
  '^\| W-21 \| Evidence must be provably executed' \
  "W-21 appears in the generated universal rule table"

printf '\n\033[1mTotal: %d  Passed: %d  Failed: %d\033[0m\n' "$TOTAL" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]

#!/usr/bin/env bash
# VibeGuard CI: Verify that the rule file is in the correct format
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RULES_DIR="${REPO_DIR}/rules"
errors=0

echo "Validating rule files..."

# Check that all rule files exist and are not empty
for rule_file in universal.md python.md typescript.md go.md rust.md security.md; do
  path="${RULES_DIR}/${rule_file}"
  if [[ ! -f "$path" ]]; then
    echo "FAIL: ${rule_file} not found"
    ((errors++))
  elif [[ ! -s "$path" ]]; then
    echo "FAIL: ${rule_file} is empty"
    ((errors++))
  else
    echo "OK: ${rule_file}"
  fi
done

# Check that the rule file contains the necessary table structure
echo
echo "Checking rule file structure..."
for rule_file in "${RULES_DIR}"/*.md; do
  [[ -f "$rule_file" ]] || continue
  name=$(basename "$rule_file")
  [[ "$name" == "CLAUDE.md" ]] && continue

  if ! grep -q '| ID' "$rule_file" 2>/dev/null; then
    echo "WARN: ${name} missing ID column in table"
  fi

  if ! grep -q 'Severity\|Severe\|High\|Medium\|Low' "$rule_file" 2>/dev/null; then
    echo "WARN: ${name} missing severity indicators"
  fi
done

echo
echo "Checking canonical rule applicability boundaries..."
DATA_CONSISTENCY_RULE="${RULES_DIR}/claude-rules/common/data-consistency.md"
EVAL_VALIDATION_RULE="${RULES_DIR}/claude-rules/common/eval-validation.md"
WORKFLOW_RULE="${RULES_DIR}/claude-rules/common/workflow.md"

if grep -q '^paths:' "${DATA_CONSISTENCY_RULE}" && grep -q '^## Applicability' "${DATA_CONSISTENCY_RULE}"; then
  echo "OK: data-consistency.md has path and applicability scope"
else
  echo "FAIL: data-consistency.md must declare paths and an Applicability section"
  ((errors++))
fi

if [[ -f "${EVAL_VALIDATION_RULE}" ]] && grep -q '^paths:' "${EVAL_VALIDATION_RULE}" && grep -q '^## W-18:' "${EVAL_VALIDATION_RULE}" && grep -q '^## Applicability' "${EVAL_VALIDATION_RULE}"; then
  echo "OK: eval-validation.md scopes W-18"
else
  echo "FAIL: eval-validation.md must exist with paths, W-18, and an Applicability section"
  ((errors++))
fi

if grep -q '^## W-18:' "${WORKFLOW_RULE}"; then
  echo "FAIL: W-18 must stay in eval-validation.md so workflow.md remains broadly scoped"
  ((errors++))
else
  echo "OK: workflow.md does not carry W-18"
fi

# Check vibeguard-rules.md index file
RULES_INDEX="${REPO_DIR}/claude-md/vibeguard-rules.md"
if [[ -f "$RULES_INDEX" ]]; then
  if grep -q 'vibeguard-start' "$RULES_INDEX" && grep -q 'vibeguard-end' "$RULES_INDEX"; then
    echo "OK: vibeguard-rules.md has proper markers"
  else
    echo "FAIL: vibeguard-rules.md missing start/end markers"
    ((errors++))
  fi
else
  echo "FAIL: vibeguard-rules.md not found"
  ((errors++))
fi

echo
if [[ ${errors} -eq 0 ]]; then
  echo "All rule files valid."
else
  echo "FAILED: ${errors} errors found."
  exit 1
fi

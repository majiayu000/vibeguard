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

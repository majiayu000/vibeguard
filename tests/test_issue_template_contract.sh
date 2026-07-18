#!/usr/bin/env bash
# Validate the GitHub issue chooser contract.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE_DIR="${REPO_DIR}/.github/ISSUE_TEMPLATE"
CI_WORKFLOW="${REPO_DIR}/.github/workflows/ci.yml"
LOCAL_GATE="${REPO_DIR}/scripts/local-contract-check.sh"

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header(){ printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

assert_equals() {
  local expected="$1" actual="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" == "$expected" ]]; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected: $expected, actual: $actual)"
    FAIL=$((FAIL + 1))
  fi
}

assert_empty() {
  local actual="$1" desc="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -z "$actual" ]]; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (unexpected: $actual)"
    FAIL=$((FAIL + 1))
  fi
}

top_level_values() {
  local file="$1" key="$2"
  awk -v key="$key" '
    index($0, key ":") == 1 {
      value = substr($0, length(key) + 2)
      sub(/^[[:space:]]*/, "", value)
      sub(/[[:space:]]*$/, "", value)
      print value
    }
  ' "$file"
}

header "issue template inventory"
expected_templates=$'bug_report.yml\nconfig.yml\nfalse_positive.yml\nfeature_request.yml'
actual_templates="$(
  find "$TEMPLATE_DIR" -maxdepth 1 -type f -print \
    | sed "s#${TEMPLATE_DIR}/##" \
    | sort
)"
assert_equals "$expected_templates" "$actual_templates" \
  "only canonical structured templates are exposed"

header "issue chooser names"
bug_name="$(top_level_values "$TEMPLATE_DIR/bug_report.yml" "name")"
feature_name="$(top_level_values "$TEMPLATE_DIR/feature_request.yml" "name")"
false_positive_name="$(top_level_values "$TEMPLATE_DIR/false_positive.yml" "name")"
assert_equals "Bug Report" "$bug_name" "bug form uses the canonical unquoted name"
assert_equals "Feature Request" "$feature_name" "feature form uses the canonical unquoted name"
assert_equals "False Positive Report" "$false_positive_name" \
  "false-positive form uses the canonical unquoted name"
form_names="$(printf '%s\n%s\n%s\n' "$bug_name" "$feature_name" "$false_positive_name")"
form_count="$(printf '%s\n' "$form_names" | awk 'NF { count++ } END { print count + 0 }')"
duplicate_names="$(printf '%s\n' "$form_names" | awk 'NF' | sort | uniq -d)"
assert_equals "3" "$form_count" "all three issue forms declare a name"
assert_empty "$duplicate_names" "issue form names are unique"

header "issue labels and blank issue policy"
assert_equals '["bug"]' "$(top_level_values "$TEMPLATE_DIR/bug_report.yml" "labels")" \
  "bug reports use the repository bug label"
assert_equals '["enhancement"]' \
  "$(top_level_values "$TEMPLATE_DIR/feature_request.yml" "labels")" \
  "feature requests use the repository enhancement label"
assert_equals '["false positive"]' \
  "$(top_level_values "$TEMPLATE_DIR/false_positive.yml" "labels")" \
  "false-positive reports use the existing repository label"
assert_equals 'true' "$(top_level_values "$TEMPLATE_DIR/config.yml" "blank_issues_enabled")" \
  "blank issues remain available while Discussions are disabled"

header "gate wiring"
ci_invocations="$(grep -Ec '^[[:space:]]*run:[[:space:]]+bash[[:space:]]+tests/test_issue_template_contract\.sh[[:space:]]*$' "$CI_WORKFLOW" || true)"
assert_equals "2" "$ci_invocations" "Linux/macOS and Windows CI run the contract"
local_invocations="$(grep -Ec '^[[:space:]]*run_check "test_issue_template_contract" "\$REPO_DIR/tests/test_issue_template_contract\.sh" "false"[[:space:]]*$' "$LOCAL_GATE" || true)"
assert_equals "1" "$local_invocations" "local contract gate runs the issue template contract"

printf '\n==============================\n'
printf 'Total: %d  Pass: %d  Fail: %d\n' "$TOTAL" "$PASS" "$FAIL"
printf '==============================\n'

exit $((FAIL > 0 ? 1 : 0))

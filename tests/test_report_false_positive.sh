#!/usr/bin/env bash
# Regression tests for scripts/report-false-positive.py.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${REPO_DIR}/scripts/report-false-positive.py"

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }

assert_contains() {
  local output="$1" expected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qF -- "$expected" <<< "$output"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected: $expected)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local output="$1" unexpected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qF -- "$unexpected" <<< "$output"; then
    red "$desc (unexpected: $unexpected)"
    FAIL=$((FAIL + 1))
  else
    green "$desc"
    PASS=$((PASS + 1))
  fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

EVENT_LOG="${TMP_DIR}/events.jsonl"
cat > "$EVENT_LOG" <<'JSONL'
{"schema_version":1,"ts":"2026-06-19T00:00:00Z","session":"s1","event_id":"VG-POLICY-RS03-DOC-EXAMPLE","code":"VG-POLICY-RS03-DOC-EXAMPLE","rule_id":"RS-03","hook":"post-edit-guard","tool":"Edit","decision":"warn","status":"warn","path":"docs/example.rs","reason":"documentation sample includes unwrap token=ghp_secretvalue"}
JSONL

markdown_out="$(python3 "$SCRIPT" VG-POLICY-RS03-DOC-EXAMPLE --event-log "$EVENT_LOG")"
assert_contains "$markdown_out" "event_id: \`VG-POLICY-RS03-DOC-EXAMPLE\`" "markdown includes event id"
assert_contains "$markdown_out" "hook: \`post-edit-guard\`" "markdown includes hook"
assert_contains "$markdown_out" "rule_id: \`RS-03\`" "markdown includes rule id"
assert_contains "$markdown_out" "path: \`docs/example.rs\`" "markdown includes path"
assert_contains "$markdown_out" "token=<redacted>" "markdown redacts token assignment"
assert_not_contains "$markdown_out" "ghp_secretvalue" "markdown does not leak token value"

json_out="$(python3 "$SCRIPT" RS-03 --hook post-edit-guard --rule RS-03 --path docs/example.rs --code VG-POLICY-RS03-DOC-EXAMPLE --decision warn --status warn --remediation-context "API_KEY=sk-secret123 in copied output" --format json)"
assert_contains "$json_out" '"rule_id": "RS-03"' "json includes rule id"
assert_contains "$json_out" '"path": "docs/example.rs"' "json includes path"
assert_contains "$json_out" 'API_KEY=<redacted>' "json redacts api key"
assert_not_contains "$json_out" "sk-secret123" "json does not leak secret value"

printf '\n'
if [[ "$FAIL" -eq 0 ]]; then
  printf '\033[32mAll %d/%d tests passed\033[0m\n' "$PASS" "$TOTAL"
  exit 0
else
  printf '\033[31m%d/%d tests failed\033[0m\n' "$FAIL" "$TOTAL"
  exit 1
fi

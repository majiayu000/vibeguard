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
{"schema_version":1,"ts":"2026-06-19T00:00:01Z","session":"s1","event_id":"evt-quoted-secret","code":"VG-POLICY-QUOTED-SECRET","rule_id":"SEC-02","hook":"pre-bash-guard","tool":"Bash","decision":"block","status":"block","path":"scripts/deploy.sh","reason":"payload includes {\"password\":\"hunter2\"}, api_key: \"abc123\", password: \"correct horse battery staple\", OPENAI_API_KEY=sk-openai123, AWS_SECRET_ACCESS_KEY=\"aws secret value\", GITHUB_TOKEN=ghp_prefixedsecret, client_secret: \"client secret value\", accessToken=\"oauth token value\", clientSecret=\"client js secret\", privateKey=\"private key value\", and password=\"abc\\\"def secret\""}
{"schema_version":1,"ts":"2026-06-19T00:00:02Z","session":"s1","event_id":"evt-layer-token","hook":"pre-write-guard","tool":"Write","decision":"warn","status":"warn","path":"src/new.rs","reason":"VIBEGUARD [L1] [advisory] new source file detected"}
{"schema_version":1,"ts":"2026-06-19T00:00:03Z","session":"s1","event_id":"evt-detail-path","code":"VG-POLICY-DETAIL-PATH","rule_id":"RS-03","hook":"post-edit-guard","tool":"Edit","decision":"warn","status":"warn","detail":"src/lib.rs||delta=12","reason":"VIBEGUARD [RS-03] unwrap"}
{"schema_version":1,"ts":"2026-06-19T00:00:04Z","session":"s1","event_id":"evt-legacy-detail","code":"VG-POLICY-LEGACY-DETAIL","rule_id":"RS-03","hook":"post-edit-guard","tool":"Edit","decision":"warn","status":"warn","detail":"Edit src/foo.ts","reason":"VIBEGUARD [RS-03] unwrap"}
JSONL

PREFIX_EVENT_LOG="${TMP_DIR}/events-prefix.jsonl"
cat > "$PREFIX_EVENT_LOG" <<'JSONL'
{"schema_version":1,"ts":"2026-06-19T00:00:00Z","session":"s1","event_id":"evt-rs03","hook":"post-edit-guard","tool":"Edit","decision":"warn","status":"warn","path":"docs/match.rs","reason":"VIBEGUARD [RS-03] unwrap"}
{"schema_version":1,"ts":"2026-06-19T00:00:01Z","session":"s1","event_id":"evt-rs030","hook":"post-edit-guard","tool":"Edit","decision":"warn","status":"warn","path":"docs/wrong.rs","reason":"VIBEGUARD [RS-030] unwrap"}
JSONL

markdown_out="$(python3 "$SCRIPT" VG-POLICY-RS03-DOC-EXAMPLE --event-log "$EVENT_LOG")"
assert_contains "$markdown_out" "event_id: \`VG-POLICY-RS03-DOC-EXAMPLE\`" "markdown includes event id"
assert_contains "$markdown_out" "hook: \`post-edit-guard\`" "markdown includes hook"
assert_contains "$markdown_out" "rule_id: \`RS-03\`" "markdown includes rule id"
assert_contains "$markdown_out" "path: \`docs/example.rs\`" "markdown includes path"
assert_contains "$markdown_out" "token=<redacted>" "markdown redacts token assignment"
assert_not_contains "$markdown_out" "ghp_secretvalue" "markdown does not leak token value"

quoted_secret_out="$(python3 "$SCRIPT" evt-quoted-secret --event-log "$EVENT_LOG")"
assert_contains "$quoted_secret_out" "code: \`VG-POLICY-QUOTED-SECRET\`" "markdown reads code from code field before event_id"
assert_contains "$quoted_secret_out" "password=<redacted>" "markdown redacts quoted JSON password"
assert_contains "$quoted_secret_out" "api_key=<redacted>" "markdown redacts quoted YAML-style api key"
assert_contains "$quoted_secret_out" "OPENAI_API_KEY=<redacted>" "markdown redacts prefixed openai api key"
assert_contains "$quoted_secret_out" "AWS_SECRET_ACCESS_KEY=<redacted>" "markdown redacts prefixed aws secret key"
assert_contains "$quoted_secret_out" "GITHUB_TOKEN=<redacted>" "markdown redacts prefixed github token"
assert_contains "$quoted_secret_out" "client_secret=<redacted>" "markdown redacts client secret"
assert_contains "$quoted_secret_out" "accessToken=<redacted>" "markdown redacts camelCase access token"
assert_contains "$quoted_secret_out" "clientSecret=<redacted>" "markdown redacts camelCase client secret"
assert_contains "$quoted_secret_out" "privateKey=<redacted>" "markdown redacts camelCase private key"
assert_not_contains "$quoted_secret_out" "hunter2" "markdown does not leak quoted JSON password"
assert_not_contains "$quoted_secret_out" "abc123" "markdown does not leak quoted YAML-style api key"
assert_not_contains "$quoted_secret_out" "correct horse battery staple" "markdown does not leak multi-word quoted password"
assert_not_contains "$quoted_secret_out" "sk-openai123" "markdown does not leak prefixed openai api key"
assert_not_contains "$quoted_secret_out" "aws secret value" "markdown does not leak prefixed aws secret key"
assert_not_contains "$quoted_secret_out" "ghp_prefixedsecret" "markdown does not leak prefixed github token"
assert_not_contains "$quoted_secret_out" "client secret value" "markdown does not leak client secret"
assert_not_contains "$quoted_secret_out" "oauth token value" "markdown does not leak camelCase access token"
assert_not_contains "$quoted_secret_out" "client js secret" "markdown does not leak camelCase client secret"
assert_not_contains "$quoted_secret_out" "private key value" "markdown does not leak camelCase private key"
assert_not_contains "$quoted_secret_out" "def secret" "markdown does not leak escaped-quote secret suffix"

layer_rule_out="$(python3 "$SCRIPT" L1 --event-log "$EVENT_LOG")"
assert_contains "$layer_rule_out" "rule_id: \`L1\`" "markdown extracts rule id from reason token"

detail_path_out="$(python3 "$SCRIPT" evt-detail-path --event-log "$EVENT_LOG")"
assert_contains "$detail_path_out" "path: \`src/lib.rs\`" "markdown extracts path from structured detail"
assert_not_contains "$detail_path_out" "src/lib.rs||delta=12" "markdown does not report structured detail as path"

legacy_detail_out="$(python3 "$SCRIPT" evt-legacy-detail --event-log "$EVENT_LOG")"
assert_contains "$legacy_detail_out" "path: \`unknown\`" "markdown does not treat legacy free-form detail as path"
assert_not_contains "$legacy_detail_out" "path: \`Edit src/foo.ts\`" "markdown does not report free-form detail as path"

prefix_rule_out="$(python3 "$SCRIPT" RS-03 --event-log "$PREFIX_EVENT_LOG")"
assert_contains "$prefix_rule_out" "path: \`docs/match.rs\`" "rule lookup matches whole token"
assert_not_contains "$prefix_rule_out" "docs/wrong.rs" "rule lookup does not match longer token prefix"

json_out="$(python3 "$SCRIPT" RS-03 --hook post-edit-guard --rule RS-03 --path docs/example.rs --code VG-POLICY-RS03-DOC-EXAMPLE --decision warn --status warn --remediation-context "API_KEY=sk-secret123 in copied output" --format json)"
assert_contains "$json_out" '"rule_id": "RS-03"' "json includes rule id"
assert_contains "$json_out" '"path": "docs/example.rs"' "json includes path"
assert_contains "$json_out" 'API_KEY=<redacted>' "json redacts api key"
assert_not_contains "$json_out" "sk-secret123" "json does not leak secret value"

set +e
missing_event_out="$(python3 "$SCRIPT" VG-MISSING-EVENT --event-log "$EVENT_LOG" 2>&1)"
missing_event_status=$?
set -e
if [[ "${missing_event_status}" -ne 0 ]]; then
  green "missing event exits nonzero"
  PASS=$((PASS + 1))
else
  red "missing event exits nonzero"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
assert_contains "$missing_event_out" "event id not found in event log: VG-MISSING-EVENT" "missing event reports absent id"
assert_not_contains "$missing_event_out" '"hook": "unknown"' "missing event does not emit unknown report"

# GH-675: recording the triage verdict must happen in the same call that
# produces the report, instead of printing an instruction nobody runs.
triage_dir="$(mktemp -d)"
trap 'rm -rf "${triage_dir}"' EXIT
triage_file="${triage_dir}/triage.jsonl"
scorecard_file="${triage_dir}/rule-scorecard.json"

record_out="$(python3 "${SCRIPT}" VG-TEST-RECORD --rule RS-03 --code VG-POLICY-RS03 \
  --record-triage fp --triage-file "${triage_file}" --scorecard-file "${scorecard_file}" 2>&1)"
assert_contains "$record_out" "Recorded fp for RS-03" "--record-triage records the verdict"

TOTAL=$((TOTAL + 1))
if [[ -f "${triage_file}" ]] && grep -q '"verdict": "fp"' "${triage_file}" \
  && grep -q '"rule": "RS-03"' "${triage_file}"; then
  green "--record-triage appends a triage record"
  PASS=$((PASS + 1))
else
  red "--record-triage appends a triage record"
  FAIL=$((FAIL + 1))
fi

TOTAL=$((TOTAL + 1))
if [[ -f "${scorecard_file}" ]]; then
  green "--record-triage updates the scorecard"
  PASS=$((PASS + 1))
else
  red "--record-triage updates the scorecard"
  FAIL=$((FAIL + 1))
fi

# The context must not be filled with placeholder text.
assert_not_contains "$(cat "${triage_file}")" "unknown unknown" \
  "recorded context omits unknown placeholders"

# Without a rule id there is nothing to attribute the verdict to: fail loudly
# rather than emit a report that looks recorded but is not.
set +e
norule_out="$(python3 "${SCRIPT}" VG-TEST-NORULE --record-triage fp \
  --triage-file "${triage_file}" --scorecard-file "${scorecard_file}" 2>&1)"
norule_status=$?
set -e
TOTAL=$((TOTAL + 1))
if [[ "${norule_status}" -ne 0 ]]; then
  green "--record-triage without a rule id exits nonzero"
  PASS=$((PASS + 1))
else
  red "--record-triage without a rule id exits nonzero"
  FAIL=$((FAIL + 1))
fi
assert_contains "$norule_out" "needs a rule id" "--record-triage names the missing rule id"

TOTAL=$((TOTAL + 1))
if [[ "$(grep -c '"verdict"' "${triage_file}")" == "1" ]]; then
  green "a rejected record leaves no triage entry"
  PASS=$((PASS + 1))
else
  red "a rejected record leaves no triage entry"
  FAIL=$((FAIL + 1))
fi

# Default behavior is unchanged when the flag is absent.
plain_out="$(python3 "${SCRIPT}" VG-TEST-PLAIN --rule RS-03 2>&1)"
assert_not_contains "$plain_out" "Recorded fp" "no verdict is recorded without --record-triage"

printf '\n'
if [[ "$FAIL" -eq 0 ]]; then
  printf '\033[32mAll %d/%d tests passed\033[0m\n' "$PASS" "$TOTAL"
  exit 0
else
  printf '\033[31m%d/%d tests failed\033[0m\n' "$FAIL" "$TOTAL"
  exit 1
fi

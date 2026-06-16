#!/usr/bin/env bash
# Regression tests for events.jsonl and session-metrics.jsonl schema contracts.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES_DIR="${REPO_DIR}/tests/fixtures/observability-schemas"

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
    red "$desc (cmd: $*)"
    FAIL=$((FAIL + 1))
  fi
}

assert_fails() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    red "$desc (expected failure)"
    FAIL=$((FAIL + 1))
  else
    green "$desc"
    PASS=$((PASS + 1))
  fi
}

run_schema_check() {
  local schema_file="$1"
  local fixture_file="$2"
  local mode="${3:-strict}"
  python3 - "${REPO_DIR}" "${schema_file}" "${fixture_file}" "${mode}" <<'PY'
import importlib.util
import json
import sys
from pathlib import Path

repo = Path(sys.argv[1])
schema_path = repo / sys.argv[2]
fixture_path = Path(sys.argv[3])
mode = sys.argv[4]

spec = importlib.util.spec_from_file_location(
    "workflow_contracts",
    repo / "scripts/lib/workflow_contracts.py",
)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)

schema = json.loads(schema_path.read_text(encoding="utf-8"))

if mode == "utf8_lossy_hex":
    raw_lines = [bytes.fromhex(fixture_path.read_text(encoding="ascii").strip())]
else:
    raw_lines = fixture_path.read_bytes().splitlines()

errors = []
valid_rows = 0
for line_number, raw_line in enumerate(raw_lines, start=1):
    if not raw_line:
        continue
    text = raw_line.decode("utf-8", errors="replace")
    try:
        row = json.loads(text)
    except json.JSONDecodeError as exc:
        if mode == "skip_invalid_json":
            continue
        errors.append(f"{fixture_path}:{line_number}: invalid JSON: {exc.msg}")
        continue
    if not isinstance(row, dict):
        errors.append(f"{fixture_path}:{line_number}: row must be a JSON object")
        continue
    row_errors = module.validate_instance(row, schema)
    if row_errors:
        errors.extend(f"{fixture_path}:{line_number}: {error}" for error in row_errors)
    else:
        valid_rows += 1

if mode == "skip_invalid_json" and valid_rows == 0:
    errors.append(f"{fixture_path}: expected at least one valid row after skipping malformed JSON")
if mode == "utf8_lossy_hex" and valid_rows != 1:
    errors.append(f"{fixture_path}: expected one recovered UTF-8 row, got {valid_rows}")

if errors:
    raise SystemExit("\n".join(errors))
PY
}

header "event log schema"
assert_cmd "current events.jsonl rows validate" \
  run_schema_check "schemas/event-log.schema.json" "${FIXTURES_DIR}/events-current.jsonl"
assert_fails "missing current event-log fields fail validation" \
  run_schema_check "schemas/event-log.schema.json" "${FIXTURES_DIR}/events-missing-required.jsonl"
assert_fails "invalid decision/status values fail validation" \
  run_schema_check "schemas/event-log.schema.json" "${FIXTURES_DIR}/events-invalid-enums.jsonl"
assert_cmd "malformed JSONL rows are skipped only in reader-compatible mode" \
  run_schema_check "schemas/event-log.schema.json" "${FIXTURES_DIR}/events-malformed-json.jsonl" "skip_invalid_json"
assert_fails "malformed JSONL rows fail strict schema mode" \
  run_schema_check "schemas/event-log.schema.json" "${FIXTURES_DIR}/events-malformed-json.jsonl"
assert_cmd "malformed UTF-8 is recovered before schema validation" \
  run_schema_check "schemas/event-log.schema.json" "${FIXTURES_DIR}/events-malformed-utf8.hex" "utf8_lossy_hex"

header "session metrics schema"
assert_cmd "current session metrics rows validate" \
  run_schema_check "schemas/session-metrics.schema.json" "${FIXTURES_DIR}/session-metrics-current.jsonl"

printf '\n'
if [[ "$FAIL" -eq 0 ]]; then
  printf '\033[32mAll %d/%d tests passed\033[0m\n' "$PASS" "$TOTAL"
  exit 0
else
  printf '\033[31m%d/%d tests failed\033[0m\n' "$FAIL" "$TOTAL"
  exit 1
fi

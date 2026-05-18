#!/usr/bin/env bash
# VibeGuard workflow contract schema regression tests
#
# Usage: bash tests/test_workflow_contracts.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="${REPO_DIR}/scripts/lib/workflow_contracts.py"

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
  if echo "$output" | grep -qF "$expected"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected to contain: $expected)"
    FAIL=$((FAIL + 1))
  fi
}

assert_fails_with() {
  local desc="$1" expected="$2"
  shift 2
  local output
  local status
  TOTAL=$((TOTAL + 1))
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  if [[ ${status} -eq 0 ]]; then
    red "$desc (expected failure)"
    FAIL=$((FAIL + 1))
    return
  fi
  if echo "$output" | grep -qF "$expected"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected output to contain: $expected)"
    printf '%s\n' "$output"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

copy_schemas() {
  local target="$1"
  mkdir -p "${target}/schemas"
  cp "${REPO_DIR}"/schemas/workflow-*.schema.json "${target}/schemas/"
}

write_registry() {
  local target="$1" body="$2"
  cat > "${target}/schemas/workflow-contract-consumers.json" <<JSON
{
  "schema_version": 1,
  "schema_files": {
    "routing_decision": "workflow-routing-decision.schema.json",
    "execution_handoff": "workflow-execution-handoff.schema.json",
    "delegation_assignment": "workflow-delegation-assignment.schema.json",
    "lane_map": "workflow-lane-map.schema.json",
    "verification_gate": "workflow-verification-gate.schema.json"
  },
  ${body}
}
JSON
}

header "workflow contract validator"
assert_cmd "workflow contract helper syntax is correct" python3 -m py_compile "${HELPER}"
assert_cmd "workflow contracts validate" python3 "${HELPER}" validate
required_out="$(python3 "${HELPER}" list-required execution_handoff)"
assert_contains "${required_out}" "runtime_pinning_snapshot" "handoff required fields come from schema"

header "consumer drift failures"
HANDOFF_FIXTURE="${TMP_DIR}/handoff"
copy_schemas "${HANDOFF_FIXTURE}"
mkdir -p "${HANDOFF_FIXTURE}/agents"
python3 - "${REPO_DIR}/agents/dispatcher.md" "${HANDOFF_FIXTURE}/agents/dispatcher.md" <<'PY'
from pathlib import Path
import sys
source, target = map(Path, sys.argv[1:3])
text = source.read_text(encoding="utf-8").replace("verification_owner", "verificationOwner")
target.write_text(text, encoding="utf-8")
PY
write_registry "${HANDOFF_FIXTURE}" '"markdown_examples": [], "consumers": [{"path": "agents/dispatcher.md", "references": [], "requires": ["execution_handoff"]}], "legacy_routing_markers": []'
assert_fails_with "renamed handoff field fails consumer validation" "verification_owner" \
  python3 "${HELPER}" --repo-dir "${HANDOFF_FIXTURE}" --schema-dir "${HANDOFF_FIXTURE}/schemas" --registry "${HANDOFF_FIXTURE}/schemas/workflow-contract-consumers.json" validate

DELEGATION_FIXTURE="${TMP_DIR}/delegation"
copy_schemas "${DELEGATION_FIXTURE}"
mkdir -p "${DELEGATION_FIXTURE}/workflows/references"
python3 - "${REPO_DIR}/workflows/references/delegation-contract.md" "${DELEGATION_FIXTURE}/workflows/references/delegation-contract.md" <<'PY'
from pathlib import Path
import sys
source, target = map(Path, sys.argv[1:3])
text = source.read_text(encoding="utf-8").replace("handoff_artifacts", "handoffArtifacts")
target.write_text(text, encoding="utf-8")
PY
write_registry "${DELEGATION_FIXTURE}" '"markdown_examples": [], "consumers": [{"path": "workflows/references/delegation-contract.md", "references": [], "requires": ["delegation_assignment"]}], "legacy_routing_markers": []'
assert_fails_with "renamed delegation field fails consumer validation" "handoff_artifacts" \
  python3 "${HELPER}" --repo-dir "${DELEGATION_FIXTURE}" --schema-dir "${DELEGATION_FIXTURE}/schemas" --registry "${DELEGATION_FIXTURE}/schemas/workflow-contract-consumers.json" validate

header "markdown example failures"
EXAMPLE_FIXTURE="${TMP_DIR}/example"
copy_schemas "${EXAMPLE_FIXTURE}"
mkdir -p "${EXAMPLE_FIXTURE}/docs"
python3 - "${REPO_DIR}/docs/command-schemas.md" "${EXAMPLE_FIXTURE}/docs/command-schemas.md" <<'PY'
from pathlib import Path
import sys
source, target = map(Path, sys.argv[1:3])
text = source.read_text(encoding="utf-8").replace('"decision": "execute_direct"', '"decision": "maybe_later"', 1)
target.write_text(text, encoding="utf-8")
PY
write_registry "${EXAMPLE_FIXTURE}" '"markdown_examples": [{"path": "docs/command-schemas.md", "heading": "routing decision Schema", "schema": "routing_decision"}], "consumers": [], "legacy_routing_markers": []'
assert_fails_with "invalid command schema example fails schema validation" "maybe_later" \
  python3 "${HELPER}" --repo-dir "${EXAMPLE_FIXTURE}" --schema-dir "${EXAMPLE_FIXTURE}/schemas" --registry "${EXAMPLE_FIXTURE}/schemas/workflow-contract-consumers.json" validate

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

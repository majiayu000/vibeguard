#!/usr/bin/env bash
# Focused smoke tests for VibeGuard's adopted SpecRail pack.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

cd "${REPO_DIR}"

required_checks=(
  checks/github_pr_evidence.py
  checks/pr_gate.py
  checks/runtime_ledger_gate.py
  checks/check_workflow.py
)

required_locale_files=(
  locales/en-US/messages.yaml
  locales/zh-CN/messages.yaml
)

for check_path in "${required_checks[@]}"; do
  test -f "${check_path}"
  python3 -m py_compile "${check_path}"
done

for locale_path in "${required_locale_files[@]}"; do
  test -f "${locale_path}"
done

python3 checks/check_workflow.py --repo .
python3 checks/check_workflow.py --repo . --all-specs
python3 checks/github_pr_evidence.py --help >/dev/null

python3 checks/pr_gate.py \
  --repo . \
  --evidence examples/fixtures/pr-clean-authorized.json \
  --mode required \
  --json > "${TMP_DIR}/pr-gate.json"

python3 checks/runtime_ledger_gate.py \
  --checkpoint examples/fixtures/runtime-budget-exhausted-handoff.json \
  --json > "${TMP_DIR}/runtime-ledger-gate.json"

assert_not_allowed() {
  local output_path="$1"
  shift
  if "$@" > "${output_path}"; then
    echo "expected gate rejection: $*" >&2
    return 1
  fi
  python3 - "${output_path}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
if payload.get("decision") not in {"blocked", "needs_human"}:
    raise SystemExit(f"{path.name}: expected fail-closed decision, got {payload!r}")
PY
}

for fixture in \
  examples/fixtures/pr-missing-human-auth.json \
  examples/fixtures/pr-pending-ci.json \
  examples/fixtures/pr-unresolved-thread.json; do
  output_path="${TMP_DIR}/$(basename "${fixture}")"
  assert_not_allowed \
    "${output_path}" \
    python3 checks/pr_gate.py --repo . --evidence "${fixture}" --mode required --json
done

for fixture in \
  examples/fixtures/runtime-lane-failure-unreported.json \
  examples/fixtures/runtime-full-queue-false-complete-needs-spec.json; do
  output_path="${TMP_DIR}/$(basename "${fixture}")"
  assert_not_allowed \
    "${output_path}" \
    python3 checks/runtime_ledger_gate.py --checkpoint "${fixture}" --json
done

python3 - "${TMP_DIR}/pr-gate.json" "${TMP_DIR}/runtime-ledger-gate.json" <<'PY'
import json
import sys
from pathlib import Path

for raw_path in sys.argv[1:]:
    path = Path(raw_path)
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("decision") != "allowed":
        raise SystemExit(f"{path.name}: expected allowed, got {payload!r}")
PY

echo "SpecRail adoption smoke passed"

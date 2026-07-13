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

expected_specrail_pin="e9c82f55b11826cffab9f7c95cd3f3413428ee45"
python3 - "${REPO_DIR}" "${expected_specrail_pin}" <<'PY'
import json
import sys
from pathlib import Path

repo = Path(sys.argv[1]).resolve()
expected_pin = sys.argv[2]
sys.path.insert(0, str(repo / "checks"))

from specrail_lib import artifact_templates, load_pack, resolve_repo_path

usage_text = (repo / "AGENT_USAGE.md").read_text(encoding="utf-8")
if expected_pin not in usage_text:
    raise SystemExit(f"AGENT_USAGE.md: missing SpecRail adoption pin {expected_pin}")

config = load_pack(repo)
artifacts = artifact_templates(config)
if artifacts.get("spec_packet", "").rstrip("/") != "docs/specs/GH{issue_number}":
    raise SystemExit("workflow.yaml: VibeGuard spec packet root must remain docs/specs")
presentation = config.workflow.get("presentation", {})
if presentation.get("default_locale") != "zh-CN":
    raise SystemExit("workflow.yaml: VibeGuard default locale must remain zh-CN")
automation_policy = config.workflow.get("automation_policy", {})
if automation_policy.get("auth_mode") != "review":
    raise SystemExit("workflow.yaml: persisted auth_mode must remain review")

matrix_path = repo / "examples" / "adoptions" / "matrix.json"
matrix = json.loads(matrix_path.read_text(encoding="utf-8"))
for adoption in matrix.get("adoptions", []):
    adoption_id = adoption.get("id", "unknown")
    for index, evidence in enumerate(adoption.get("evidence", [])):
        if evidence.get("kind") != "specrail_artifact":
            continue
        raw_path = evidence.get("path")
        if not isinstance(raw_path, str) or not raw_path:
            raise SystemExit(
                f"matrix {adoption_id} evidence {index}: missing local artifact path"
            )
        resolved_path = resolve_repo_path(
            repo,
            raw_path,
            label=f"matrix {adoption_id} evidence {index}",
        )
        if not resolved_path.is_file():
            raise SystemExit(
                f"matrix {adoption_id} evidence {index}: missing {raw_path}"
            )
PY

python3 checks/check_workflow.py --repo .
python3 checks/check_workflow.py --repo . --all-specs
python3 checks/github_pr_evidence.py --help >/dev/null

python3 checks/route_gate.py \
  --repo . \
  --route implement \
  --issue 539 \
  --state ready_to_implement \
  --artifact product_spec=README.md \
  --json > "${TMP_DIR}/configured-artifact-gate.json"

python3 - "${TMP_DIR}/configured-artifact-gate.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
expected = "docs/specs/GH539/product.md"
if f"product_spec:{expected}" not in payload.get("missing", []):
    raise SystemExit(f"{path.name}: configured product spec was not reported missing")
if "product_spec: README.md" in payload.get("satisfied", []):
    raise SystemExit(f"{path.name}: stale product spec path was accepted")
if not any(
    "product_spec provided at README.md does not match "
    f"configured path {expected}" in reason
    for reason in payload.get("reasons", [])
):
    raise SystemExit(f"{path.name}: configured path mismatch reason missing")
PY

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

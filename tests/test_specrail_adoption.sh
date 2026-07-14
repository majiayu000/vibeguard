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

expected_specrail_pin="7de16e4780d903607b40220a9edb7a08fe222c78"
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

workflow_check_text = (
    repo / ".github" / "workflows" / "workflow-check.yml"
).read_text(encoding="utf-8")
for token in [
    "fetch-depth: 0",
    'diff_range="${BASE_SHA}...${HEAD_SHA}"',
    'diff_range="${BASE_SHA}..${HEAD_SHA}"',
    'git diff --check "${diff_range}"',
]:
    if token not in workflow_check_text:
        raise SystemExit(f"workflow-check.yml: missing committed diff check token {token}")

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

python3 - "${REPO_DIR}" "${TMP_DIR}" <<'PY'
import json
import shutil
import subprocess
import sys
from pathlib import Path, PurePosixPath

repo = Path(sys.argv[1]).resolve()
tmp = Path(sys.argv[2]).resolve()
sys.path.insert(0, str(repo / "checks"))

import check_workflow
from check_workflow import discover_spec_packet_dirs, validate_pack_assets
from specrail_lib import SpecRailError

asset_target = tmp / "asset-target"
shutil.copytree(repo / "schemas", asset_target / "schemas")
shutil.copytree(repo / "templates", asset_target / "templates")
target_helper = asset_target / "checks" / "pack_asset_validation.py"
target_helper.parent.mkdir()
target_helper.write_text(
    "from pathlib import Path\n"
    "Path(__file__).with_name('target-helper-executed').write_text('yes')\n"
    "def validate_json_schemas(repo):\n"
    "    return []\n"
    "def validate_template_parity(repo):\n"
    "    return []\n",
    encoding="utf-8",
)
(asset_target / "schemas" / "workflow_run.schema.json").unlink()
asset_errors = validate_pack_assets(asset_target)
if "schemas: missing SpecRail schema workflow_run.schema.json" not in asset_errors:
    raise SystemExit(f"trusted asset validation was weakened: {asset_errors!r}")
if target_helper.with_name("target-helper-executed").exists():
    raise SystemExit("target-controlled pack asset helper was executed")

original_check_file = check_workflow.__file__
check_workflow.__file__ = str(tmp / "missing-runner" / "checks" / "check_workflow.py")
try:
    missing_source_errors = validate_pack_assets(repo)
finally:
    check_workflow.__file__ = original_check_file
if not any("trusted pack asset validation" in item for item in missing_source_errors):
    raise SystemExit(
        f"missing trusted source helper did not fail closed: {missing_source_errors!r}"
    )

root_repo = tmp / "root-repo"
root_repo.mkdir()
for root_name, expected in [
    ("missing-specs", "does not exist"),
    ("regular-specs", "not a directory"),
]:
    if root_name == "regular-specs":
        (root_repo / root_name).write_text("not a directory\n", encoding="utf-8")
    try:
        discover_spec_packet_dirs(root_repo, PurePosixPath(root_name))
    except SpecRailError as exc:
        if expected not in str(exc):
            raise SystemExit(f"unexpected configured root error: {exc}") from exc
    else:
        raise SystemExit(f"configured spec root {root_name} did not fail closed")

route_repo = tmp / "route-repo"
route_repo.mkdir()
workflow_text = (repo / "workflow.yaml").read_text(encoding="utf-8").replace(
    "docs/specs/GH{issue_number}",
    "docs/specs/./GH{issue_number}",
)
(route_repo / "workflow.yaml").write_text(workflow_text, encoding="utf-8")
for name in ["states.yaml", "labels.yaml"]:
    shutil.copy2(repo / name, route_repo / name)
schema_dir = route_repo / "schemas"
schema_dir.mkdir()
shutil.copy2(
    repo / "schemas" / "duplicate_work_evidence.schema.json",
    schema_dir / "duplicate_work_evidence.schema.json",
)
packet = route_repo / "docs" / "specs" / "GH595"
packet.mkdir(parents=True)
for name in ["product.md", "tech.md"]:
    (packet / name).write_text("GitHub issue: `#595`\n", encoding="utf-8")
duplicate_evidence = tmp / "duplicate-work-evidence.json"
duplicate_evidence.write_text(
    json.dumps(
        {
            "issue": 595,
            "collected_at": "2026-07-14T00:00:00Z",
            "open_prs_complete": True,
            "open_pr_limit": 100,
            "open_prs": [],
            "remote_branches": [],
        }
    ),
    encoding="utf-8",
)
for artifact_prefix in ["docs/specs", "docs/specs/."]:
    command = [
        sys.executable,
        str(repo / "checks" / "route_gate.py"),
        "--repo",
        str(route_repo),
        "--route",
        "implement",
        "--issue",
        "595",
        "--state",
        "ready_to_implement",
        "--duplicate-evidence",
        str(duplicate_evidence),
        "--artifact",
        f"product_spec={artifact_prefix}/GH595/product.md",
        "--artifact",
        f"tech_spec={artifact_prefix}/GH595/tech.md",
        "--mode",
        "required",
        "--json",
    ]
    result = subprocess.run(command, check=False, capture_output=True, text=True)
    payload = json.loads(result.stdout)
    if result.returncode != 0 or payload.get("decision") != "allowed":
        raise SystemExit(
            f"normalized configured artifact evidence was rejected: {payload!r}"
        )
    if "product_spec: docs/specs/GH595/product.md" not in payload.get(
        "satisfied", []
    ):
        raise SystemExit(f"normalized product path missing: {payload!r}")
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

missing_auth_output="${TMP_DIR}/pr-missing-human-auth.json"
assert_not_allowed \
  "${missing_auth_output}" \
  python3 checks/pr_gate.py \
    --repo . \
    --evidence examples/fixtures/pr-missing-human-auth.json \
    --mode required \
    --json

python3 - "${missing_auth_output}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
if payload.get("decision") != "needs_human":
    raise SystemExit(
        f"{path.name}: missing human auth must be needs_human, got {payload!r}"
    )
PY

for fixture in \
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

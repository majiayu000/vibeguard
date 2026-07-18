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
  cp "${REPO_DIR}"/schemas/*.schema.json "${target}/schemas/"
}

write_registry() {
  local target="$1" body="$2"
  cat > "${target}/schemas/workflow-contract-consumers.json" <<JSON
{
  "schema_version": 1,
  "schema_files": {
    "check_output": "command-check-output.schema.json",
    "learn_output": "command-learn-output.schema.json",
    "live_truth_output": "command-live-truth-output.schema.json",
    "preflight_output": "command-preflight-output.schema.json",
    "review_output": "command-review-output.schema.json",
    "skill_validate_output": "command-skill-validate-output.schema.json",
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
TOTAL=$((TOTAL + 1))
if python3 - "${REPO_DIR}" >/dev/null <<'PY'; then
import importlib.util, json, sys
from pathlib import Path
repo = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("workflow_contracts", repo / "scripts/lib/workflow_contracts.py")
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
schema = json.loads((repo / "schemas/workflow-routing-decision.schema.json").read_text(encoding="utf-8"))
precedence = ["user_override", "work_surface_classifier", "risk_destructive_gate", "ambiguity_gate", "readiness_classifier", "execution_or_delegation_lane"]
def payload(surface):
    return {"precedence": precedence, "work_surface": {"decision": surface, "reason": "Complete classification evidence"}, "readiness": {"decision": "clarify_first", "reason": "Need scope confirmation", "blocking_questions": ["Which path is in scope?"]}}
for surface in ["code_execution", "writing_research", "chat_support"]:
    errors = module.validate_instance(payload(surface), schema)
    if errors:
        raise SystemExit(f"valid {surface}: " + "\n".join(errors))
valid = payload("code_execution")
invalid = [
    {key: value for key, value in valid.items() if key != "work_surface"},
    valid | {"work_surface": {"decision": "unknown", "reason": "invalid"}},
    valid | {"work_surface": {"decision": "code_execution", "reason": ""}},
    {key: value for key, value in valid.items() if key != "precedence"},
    valid | {"precedence": [precedence[1], precedence[0], *precedence[2:]]},
    valid | {"precedence": [*precedence[:-1], precedence[-2]]},
    valid | {"precedence": [*precedence, "extra_stage"]},
]
if any(not module.validate_instance(candidate, schema) for candidate in invalid):
    raise SystemExit("routing schema accepted a missing, invalid, reordered, duplicated, or extra field")
contract = (repo / "workflows/references/routing-contract.md").read_text(encoding="utf-8")
for token in ["must not emit a partial", "Consumers never reclassify locally", "does not create an execution handoff", "later executors require both objects"]:
    if token not in contract:
        raise SystemExit(f"routing contract missing: {token}")
PY
  green "routing schema and consumer contract enforce work-surface routing"
  PASS=$((PASS + 1))
else
  red "routing schema and consumer contract enforce work-surface routing"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
if python3 - "${REPO_DIR}" >/dev/null <<'PY'; then
import importlib.util
import json
import sys
from pathlib import Path

repo = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("workflow_contracts", repo / "scripts/lib/workflow_contracts.py")
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
schema = json.loads((repo / "schemas/command-skill-validate-output.schema.json").read_text(encoding="utf-8"))
payload = {
    "command": "skill_validate",
    "mode": "evidence",
    "skill_name": "demo-skill",
    "proposed_skill": "/tmp/demo/SKILL.md",
    "decision_set": "baseline",
    "verdict": "pass",
    "counts": {
        "repair": 1,
        "regression": 0,
        "no_change": 2,
        "unrelated_regression": 0,
        "unrelated_no_change": 2,
    },
    "freshness_gaps": [],
    "reasons": ["repair count is greater than regression count with no regressions"],
    "regression_justification": None,
    "scored_against_agent": "claude-opus-4-7",
    "scored_at": "2026-05-31",
    "artifact_path": ".vibeguard/skill-validate/demo-skill-2026-05-31.jsonl",
    "scenarios": [
        {
            "scenario_id": "incident-1",
            "scenario_type": "target",
            "without_skill": "failure",
            "with_skill": "success",
            "classification": "repair",
            "source": "baseline",
            "scored_against_agent": "claude-opus-4-7",
            "scored_at": "2026-05-31",
            "notes": None,
        }
    ],
}
errors = module.validate_instance(payload, schema)
if errors:
    raise SystemExit("\n".join(errors))
PY
  green "skill_validate schema accepts persisted artifact fields"
  PASS=$((PASS + 1))
else
  red "skill_validate schema accepts persisted artifact fields"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
if python3 - "${REPO_DIR}" >/dev/null <<'PY'; then
import importlib.util
import json
import sys
from pathlib import Path

repo = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("workflow_contracts", repo / "scripts/lib/workflow_contracts.py")
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
schema = json.loads((repo / "schemas/command-skill-validate-output.schema.json").read_text(encoding="utf-8"))
payload = {
    "command": "skill_validate",
    "mode": "format",
    "verdict": "pass",
    "paths_checked": 1,
    "required_sections": ["## When to Activate", "## Red Flags", "## Checklist"],
    "list_required_sections": ["## Red Flags", "## Checklist"],
    "errors": [],
}
errors = module.validate_instance(payload, schema)
if errors:
    raise SystemExit("\n".join(errors))
PY
  green "skill_validate schema accepts format-only artifact fields"
  PASS=$((PASS + 1))
else
  red "skill_validate schema accepts format-only artifact fields"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
if python3 - "${REPO_DIR}" >/dev/null <<'PY'; then
import importlib.util
import json
import sys
from pathlib import Path

repo = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("workflow_contracts", repo / "scripts/lib/workflow_contracts.py")
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
schema = json.loads((repo / "schemas/command-skill-validate-output.schema.json").read_text(encoding="utf-8"))
payload = {
    "command": "skill_validate",
    "mode": "format",
    "verdict": "stale",
    "paths_checked": 1,
    "required_sections": ["## When to Activate", "## Red Flags", "## Checklist"],
    "list_required_sections": ["## Red Flags", "## Checklist"],
    "errors": [],
}
errors = module.validate_instance(payload, schema)
if not errors:
    raise SystemExit("expected stale verdict to fail for format mode")
PY
  green "skill_validate format-only artifact uses the format verdict set"
  PASS=$((PASS + 1))
else
  red "skill_validate format-only artifact uses the format verdict set"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
if python3 - "${REPO_DIR}" >/dev/null <<'PY'; then
import importlib.util
import json
import sys
from pathlib import Path

repo = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("workflow_contracts", repo / "scripts/lib/workflow_contracts.py")
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
schema = json.loads((repo / "schemas/command-skill-validate-output.schema.json").read_text(encoding="utf-8"))
payload = {
    "command": "skill_validate",
    "mode": "format",
    "verdict": "pass",
    "paths_checked": 1,
    "required_sections": ["## When to Activate", "## Red Flags", "## Checklist"],
    "list_required_sections": ["## Red Flags", "## Checklist"],
    "errors": [],
    "counts": {
        "repair": 1,
        "regression": 0,
        "no_change": 2,
        "unrelated_regression": 0,
        "unrelated_no_change": 2,
    },
}
errors = module.validate_instance(payload, schema)
if not errors:
    raise SystemExit("expected format artifact with evidence fields to fail")
PY
  green "skill_validate format-only artifact rejects evidence fields"
  PASS=$((PASS + 1))
else
  red "skill_validate format-only artifact rejects evidence fields"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
if python3 - "${REPO_DIR}" >/dev/null <<'PY'; then
import importlib.util
import json
import sys
from pathlib import Path

repo = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("workflow_contracts", repo / "scripts/lib/workflow_contracts.py")
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
schema = json.loads((repo / "schemas/command-skill-validate-output.schema.json").read_text(encoding="utf-8"))
payload = {
    "command": "skill_validate",
    "mode": "evidence",
    "skill_name": "demo-skill",
    "proposed_skill": "/tmp/demo/SKILL.md",
    "decision_set": "baseline",
    "verdict": "pass",
    "counts": {
        "repair": 1,
        "regression": 0,
        "no_change": 2,
        "unrelated_regression": 0,
        "unrelated_no_change": 2,
    },
    "freshness_gaps": [],
    "scenarios": [],
    "paths_checked": 1,
}
errors = module.validate_instance(payload, schema)
if not errors:
    raise SystemExit("expected evidence artifact with format fields to fail")
PY
  green "skill_validate evidence artifact rejects format fields"
  PASS=$((PASS + 1))
else
  red "skill_validate evidence artifact rejects format fields"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
if python3 - "${REPO_DIR}" >/dev/null <<'PY'; then
import importlib.util
import json
import sys
from copy import deepcopy
from pathlib import Path

repo = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("workflow_contracts", repo / "scripts/lib/workflow_contracts.py")
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
schema = json.loads((repo / "schemas/learn-signal.schema.json").read_text(encoding="utf-8"))
signal = {
    "schema_version": 1,
    "signal_id": "lrn_a31f7c9d",
    "observation_id": "obs_2026w26_77bc",
    "project_hash": "dc1db069",
    "project_root": "/repo",
    "type": "metrics_truncation",
    "classification": "runtime_health",
    "normalized_key": "source:learn-evaluator:metrics_truncation",
    "path": None,
    "path_relation": "unknown",
    "source_hook": "learn-evaluator",
    "source_tool": None,
    "affected_sessions": 3,
    "occurrences": 18,
    "event_rate": 0.12,
    "first_seen": "2026-06-24T00:00:00Z",
    "last_seen": "2026-06-24T12:00:00Z",
    "evidence_samples": [{"summary": "metrics input truncated"}],
    "recommended_actions": [{"type": "fix_runtime", "rationale": "runtime pipeline issue"}],
}
errors = module.validate_instance(signal, schema)
if errors:
    raise SystemExit("\n".join(errors))

bad_runtime = deepcopy(signal)
bad_runtime["recommended_actions"] = [{"type": "add_rule", "rationale": "wrong action space"}]
if not module.validate_instance(bad_runtime, schema):
    raise SystemExit("expected runtime_health add_rule to fail")

bad_truncation = deepcopy(signal)
bad_truncation.update({
    "classification": "defense_gap",
    "recommended_actions": [{"type": "add_rule", "rationale": "wrong action space"}],
})
if not module.validate_instance(bad_truncation, schema):
    raise SystemExit("expected metrics_truncation defense_gap to fail")

bad_external = deepcopy(signal)
bad_external.update({
    "type": "hot_files",
    "classification": "project_quality",
    "path": "/tmp/external.rs",
    "path_relation": "external",
    "recommended_actions": [{"type": "change_project_code", "rationale": "wrong attribution"}],
})
if not module.validate_instance(bad_external, schema):
    raise SystemExit("expected external project_quality to fail")

bad_external_gap = deepcopy(signal)
bad_external_gap.update({
    "type": "hot_files",
    "classification": "defense_gap",
    "path": "/tmp/external.rs",
    "path_relation": "external",
    "recommended_actions": [{"type": "add_rule", "rationale": "wrong attribution"}],
})
if not module.validate_instance(bad_external_gap, schema):
    raise SystemExit("expected external hot_files defense_gap to fail")
PY
  green "learn signal schema enforces classification action space"
  PASS=$((PASS + 1))
else
  red "learn signal schema enforces classification action space"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
if python3 - "${REPO_DIR}" >/dev/null <<'PY'; then
import importlib.util
import json
import sys
from copy import deepcopy
from pathlib import Path

repo = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("workflow_contracts", repo / "scripts/lib/workflow_contracts.py")
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
schema = json.loads((repo / "schemas/command-learn-output.schema.json").read_text(encoding="utf-8"))
signal_id = "lrn_a31f7c9d"
action = {"type": "fix_runtime", "rationale": "runtime pipeline issue"}
verification = {
    "status": "passed",
    "commands": ["bash tests/test_gc_scheduled.sh"],
    "notes": None,
    "evidence_observed_at": "2026-06-26T00:00:00Z",
}
adoption = {
    "schema_version": 1,
    "ts": "2026-06-25T00:00:00Z",
    "signal_id": signal_id,
    "observation_id": "obs_2026w26_77bc",
    "classification": "runtime_health",
    "selected_action": action,
    "files_or_artifacts": ["hooks/learn-evaluator.sh"],
    "original_evidence": [{"summary": "metrics input truncated"}],
    "verification_commands": ["bash tests/test_gc_scheduled.sh"],
    "regression_checks": ["bash tests/test_gc_scheduled.sh"],
    "baseline": "18 truncated sessions",
    "expected_later_observation": "truncation recurrence falls",
    "rollback_path": "revert runtime pipeline change",
    "state_transition": {"from": "new", "to": "adopted", "reason": "fix runtime"},
}
payloads = [
    {
        "command": "learn",
        "mode": "preview",
        "schema_version": 1,
        "generated_at": "2026-06-25T00:00:00Z",
        "partial": False,
        "truncated_reason": None,
        "signals": [{
            "signal_id": signal_id,
            "observation_id": "obs_2026w26_77bc",
            "classification": "runtime_health",
            "path_relation": "unknown",
            "affected_sessions": 3,
            "recommended_actions": [action],
        }],
        "diagnostics": [],
    },
    {
        "command": "learn",
        "mode": "adopt",
        "schema_version": 1,
        "signal_id": signal_id,
        "action": action,
        "state_transition": {"from": "new", "to": "adopted", "reason": "fix runtime"},
        "verification": verification,
        "adoption": adoption,
    },
    {"command": "learn", "mode": "verify", "schema_version": 1, "signal_id": signal_id, "verification": verification},
    {
        "command": "learn",
        "mode": "extract_skill",
        "schema_version": 1,
        "signal_id": signal_id,
        "skill": {"name": "debug-runtime-metrics", "path": "skills/debug-runtime-metrics/SKILL.md", "source_signal_ids": [signal_id]},
        "verification": verification,
    },
]
for payload in payloads:
    errors = module.validate_instance(payload, schema)
    if errors:
        raise SystemExit(f"{payload['mode']}: " + "\n".join(errors))

mixed_preview = deepcopy(payloads[0])
mixed_preview.update({
    "signal_id": signal_id,
    "action": action,
    "state_transition": {"from": "new", "to": "adopted", "reason": "wrong mode"},
    "verification": verification,
})
if not module.validate_instance(mixed_preview, schema):
    raise SystemExit("expected preview mixed with adopt fields to fail")
PY
  green "learn command schema accepts preview adopt verify and skill modes"
  PASS=$((PASS + 1))
else
  red "learn command schema accepts preview adopt verify and skill modes"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
if python3 - "${REPO_DIR}" >/dev/null <<'PY'; then
import json
import sys
from pathlib import Path

repo = Path(sys.argv[1])
registry = json.loads((repo / "schemas/workflow-contract-consumers.json").read_text(encoding="utf-8"))
consumers = {consumer.get("path"): consumer for consumer in registry["consumers"]}
expected = {
    ".claude/commands/vibeguard/preflight.md": {"references": {"routing-contract.md"}, "requires": {"routing_decision"}},
    "workflows/optflow/SKILL.md": {"references": {"routing-contract.md", "delegation-contract.md"}, "requires": {"routing_decision", "execution_handoff", "lane_map", "verification_gate"}},
    "workflows/plan-flow/SKILL.md": {"references": {"routing-contract.md", "delegation-contract.md"}, "requires": {"routing_decision", "execution_handoff", "lane_map", "verification_gate"}},
    "workflows/plan-mode/SKILL.md": {"references": {"routing-contract.md", "delegation-contract.md"}, "requires": {"routing_decision", "execution_handoff", "lane_map", "verification_gate"}},
    "AGENTS.md": {"references": {"routing-contract.md"}, "requires": {"routing_decision", "execution_handoff"}},
    "skills/vibeguard/SKILL.md": {"references": {"routing-contract.md"}, "requires": {"routing_decision", "execution_handoff"}},
}
for path, contract in expected.items():
    consumer = consumers.get(path)
    if consumer is None:
        raise SystemExit(f"{path} is not a workflow contract consumer")
    missing_references = contract["references"] - set(consumer.get("references", []))
    if missing_references:
        raise SystemExit(f"{path} missing references: {sorted(missing_references)}")
    missing_requires = contract["requires"] - set(consumer.get("requires", []))
    if missing_requires:
        raise SystemExit(f"{path} missing requirements: {sorted(missing_requires)}")

examples = {
    (example.get("heading"), example.get("schema"))
    for example in registry.get("markdown_examples", [])
}
expected_examples = {
    ("preflight output Schema", "preflight_output"),
    ("check output Schema", "check_output"),
    ("live_truth output Schema", "live_truth_output"),
    ("skill_validate output Schema", "skill_validate_output"),
    ("skill_validate format output Schema", "skill_validate_output"),
    ("review output Schema", "review_output"),
    ("learn output Schema", "learn_output"),
    ("learn signal Schema", "learn_signal"),
}
missing_examples = expected_examples - examples
if missing_examples:
    raise SystemExit(f"command output schema examples missing from registry: {sorted(missing_examples)}")
PY
  green "command output examples and workflow consumers stay registered"
  PASS=$((PASS + 1))
else
  red "command output examples and workflow consumers stay registered"
  FAIL=$((FAIL + 1))
fi

header "ci performance gate wiring"
TOTAL=$((TOTAL + 1))
if python3 - "${REPO_DIR}/.github/workflows/ci.yml" >/dev/null <<'PY'; then
from pathlib import Path
import sys

workflow = Path(sys.argv[1]).read_text(encoding="utf-8")
required_steps = {
    "Hook performance static analysis": "bash scripts/ci/validate-hook-perf.sh",
    "Hook performance contract regression tests": "bash tests/test_hook_perf_contract.sh",
    "Hook latency benchmark": "bash tests/bench_hook_latency.sh --runs=3 --confirmation-runs=3 --fail-on-regression",
}

for name, command in required_steps.items():
    marker = f"- name: {name}"
    start = workflow.find(marker)
    if start < 0:
        raise SystemExit(f"missing CI performance step: {name}")
    next_step = workflow.find("\n      - name:", start + len(marker))
    block = workflow[start:] if next_step < 0 else workflow[start:next_step]
    if command not in block:
        raise SystemExit(f"{name} does not run required command: {command}")
    if "continue-on-error" in block:
        raise SystemExit(f"{name} must not use continue-on-error")
PY
  green "CI performance gates stay blocking"
  PASS=$((PASS + 1))
else
  red "CI performance gates stay blocking"
  FAIL=$((FAIL + 1))
fi

header "ci setup timeout headroom"
TOTAL=$((TOTAL + 1))
if python3 - "${REPO_DIR}/.github/workflows/ci.yml" >/dev/null <<'PY'; then
from pathlib import Path
import re
import sys

def validate(workflow: str) -> None:
    job_match = re.search(
        r"(?ms)^  validate-and-test:\n(?P<body>.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)",
        workflow,
    )
    if job_match is None:
        raise SystemExit("missing validate-and-test job")
    job = job_match.group(0)
    job_lines = job.splitlines()
    required_lines = {
        "stable required check name": "    name: CI (${{ matrix.os }})",
        "finite timeout headroom": "    timeout-minutes: 45",
        "Ubuntu/macOS matrix": "        os: [ubuntu-latest, macos-latest]",
    }
    for description, line in required_lines.items():
        if line not in job_lines:
            raise SystemExit(f"validate-and-test missing {description}: {line}")
    for prefix in ("    if:", "    continue-on-error:", "        include:", "        exclude:"):
        if any(line.startswith(prefix) for line in job_lines):
            raise SystemExit(f"validate-and-test must not contain {prefix.strip()}")

    setup_match = re.search(
        r"(?ms)^      - name: Setup regression tests\n(?P<body>.*?)(?=^      - name:|\Z)",
        job,
    )
    if setup_match is None:
        raise SystemExit("missing Setup regression tests step")
    setup_lines = setup_match.group(0).splitlines()
    run_lines = [line.strip() for line in setup_lines if line.strip().startswith("run:")]
    if run_lines != ["run: bash tests/test_setup.sh"]:
        raise SystemExit("Setup regression tests must run bash tests/test_setup.sh exactly once")
    for prefix in ("if:", "continue-on-error:"):
        if any(line.strip().startswith(prefix) for line in setup_lines):
            raise SystemExit(f"Setup regression tests must not use {prefix}")


workflow = Path(sys.argv[1]).read_text(encoding="utf-8")
validate(workflow)
mutations = {
    "macOS setup skip": ("        shell: bash\n        run: bash tests/test_setup.sh", "        if: runner.os == 'Linux'\n        shell: bash\n        run: bash tests/test_setup.sh"),
    "job advisory": ("    runs-on: ${{ matrix.os }}", "    runs-on: ${{ matrix.os }}\n    continue-on-error: true"),
}
for description, (old, new) in mutations.items():
    mutated = workflow.replace(old, new, 1)
    if mutated == workflow:
        raise SystemExit(f"failed to create {description} mutation")
    try:
        validate(mutated)
    except SystemExit:
        continue
    raise SystemExit(f"contract accepted forbidden mutation: {description}")
PY
  green "CI setup stays blocking with bounded timeout headroom"
  PASS=$((PASS + 1))
else
  red "CI setup stays blocking with bounded timeout headroom"
  FAIL=$((FAIL + 1))
fi

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

COMMAND_EXAMPLE_FIXTURE="${TMP_DIR}/command-example"
copy_schemas "${COMMAND_EXAMPLE_FIXTURE}"
mkdir -p "${COMMAND_EXAMPLE_FIXTURE}/docs"
python3 - "${REPO_DIR}/docs/command-schemas.md" "${COMMAND_EXAMPLE_FIXTURE}/docs/command-schemas.md" <<'PY'
from pathlib import Path
import sys
source, target = map(Path, sys.argv[1:3])
text = source.read_text(encoding="utf-8").replace('"claim_type": "latest"', '"claim_type": "laterish"', 1)
target.write_text(text, encoding="utf-8")
PY
write_registry "${COMMAND_EXAMPLE_FIXTURE}" '"markdown_examples": [{"path": "docs/command-schemas.md", "heading": "live_truth output Schema", "schema": "live_truth_output"}], "consumers": [], "legacy_routing_markers": []'
assert_fails_with "invalid live_truth command example fails schema validation" "laterish" \
  python3 "${HELPER}" --repo-dir "${COMMAND_EXAMPLE_FIXTURE}" --schema-dir "${COMMAND_EXAMPLE_FIXTURE}/schemas" --registry "${COMMAND_EXAMPLE_FIXTURE}/schemas/workflow-contract-consumers.json" validate

header "workflow command path failures"
COMMAND_PATH_FIXTURE="${TMP_DIR}/command-path"
mkdir -p "${COMMAND_PATH_FIXTURE}/workflows/auto-optimize"
cat > "${COMMAND_PATH_FIXTURE}/workflows/auto-optimize/SKILL.md" <<'MD'
```bash
bash "${VIBEGUARD_ROOT:-$(dirname "$0")/../..}/scripts/compliance_check.sh" /path/to/project
```
MD
assert_fails_with "stale compliance check command path fails validation" "scripts/verify/compliance_check.sh" \
  bash "${REPO_DIR}/scripts/ci/validate-doc-command-paths.sh" "${COMMAND_PATH_FIXTURE}"

COMMAND_DOC_PATH_FIXTURE="${TMP_DIR}/command-doc-path"
mkdir -p \
  "${COMMAND_DOC_PATH_FIXTURE}/.claude/commands/vibeguard" \
  "${COMMAND_DOC_PATH_FIXTURE}/.claude/commands/vg"
cat > "${COMMAND_DOC_PATH_FIXTURE}/.claude/commands/vibeguard/bad.md" <<'MD'
```bash
python3 ~/vibeguard/scripts/does-not-exist.py
```
MD
cat > "${COMMAND_DOC_PATH_FIXTURE}/.claude/commands/vg/bad.md" <<'MD'
```bash
bash ~/vibeguard/scripts/missing-shortcut.sh
```
MD
set +e
command_doc_path_out="$(
  bash "${REPO_DIR}/scripts/ci/validate-doc-command-paths.sh" "${COMMAND_DOC_PATH_FIXTURE}" 2>&1
)"
command_doc_path_status=$?
set -e
TOTAL=$((TOTAL + 1))
if [[ ${command_doc_path_status} -ne 0 ]]; then
  green "command doc missing paths exit nonzero"
  PASS=$((PASS + 1))
else
  red "command doc missing paths exit nonzero (expected failure)"
  FAIL=$((FAIL + 1))
fi
assert_contains "${command_doc_path_out}" ".claude/commands/vibeguard/bad.md" "full command doc missing path fails validation"
assert_contains "${command_doc_path_out}" ".claude/commands/vg/bad.md" "shortcut command doc missing path fails validation"
assert_cmd "structured doc path allowlist fixtures pass" \
  bash "${REPO_DIR}/tests/test_doc_path_allowlist.sh"
assert_cmd "documentation metadata contracts pass" \
  bash "${REPO_DIR}/tests/test_docs_metadata_contract.sh"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

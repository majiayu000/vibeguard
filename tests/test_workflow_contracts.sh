#!/usr/bin/env bash
# Focused regression tests for VibeGuard command-output contracts.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="${REPO_DIR}/scripts/lib/workflow_contracts.py"
PASS=0
FAIL=0
TOTAL=0

assert_cmd() {
  local description="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    printf '\033[32m  PASS: %s\033[0m\n' "${description}"
    PASS=$((PASS + 1))
  else
    printf '\033[31m  FAIL: %s\033[0m\n' "${description}"
    FAIL=$((FAIL + 1))
  fi
}

assert_fails_with() {
  local description="$1" expected="$2"
  shift 2
  local output
  TOTAL=$((TOTAL + 1))
  if output="$("$@" 2>&1)"; then
    printf '\033[31m  FAIL: %s (expected failure)\033[0m\n' "${description}"
    FAIL=$((FAIL + 1))
  elif grep -qF -- "${expected}" <<< "${output}"; then
    printf '\033[32m  PASS: %s\033[0m\n' "${description}"
    PASS=$((PASS + 1))
  else
    printf '\033[31m  FAIL: %s (missing: %s)\033[0m\n' "${description}" "${expected}"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

assert_cmd "contract helper syntax is correct" python3 -m py_compile "${HELPER}"
assert_cmd "current command schemas and examples validate" python3 "${HELPER}" validate

for schema in \
  preflight_output check_output live_truth_output skill_validate_output \
  review_output learn_output learn_signal; do
  assert_cmd "registered schema is available: ${schema}" \
    python3 "${HELPER}" list-required "${schema}"
done

TOTAL=$((TOTAL + 1))
if python3 - "${REPO_DIR}" >/dev/null <<'PY'; then
import importlib.util
import json
import sys
from copy import deepcopy
from pathlib import Path

repo = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "workflow_contracts", repo / "scripts/lib/workflow_contracts.py"
)
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
  printf '\033[32m  PASS: learn signal schema enforces classification action space\033[0m\n'
  PASS=$((PASS + 1))
else
  printf '\033[31m  FAIL: learn signal schema enforces classification action space\033[0m\n'
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
spec = importlib.util.spec_from_file_location(
    "workflow_contracts", repo / "scripts/lib/workflow_contracts.py"
)
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
    {
        "command": "learn",
        "mode": "verify",
        "schema_version": 1,
        "signal_id": signal_id,
        "verification": verification,
    },
    {
        "command": "learn",
        "mode": "extract_skill",
        "schema_version": 1,
        "signal_id": signal_id,
        "skill": {
            "name": "debug-runtime-metrics",
            "path": "skills/debug-runtime-metrics/SKILL.md",
            "source_signal_ids": [signal_id],
        },
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
  printf '\033[32m  PASS: learn command schema accepts preview adopt verify and skill modes\033[0m\n'
  PASS=$((PASS + 1))
else
  printf '\033[31m  FAIL: learn command schema accepts preview adopt verify and skill modes\033[0m\n'
  FAIL=$((FAIL + 1))
fi

mkdir -p "${TMP_DIR}/schemas" "${TMP_DIR}/docs"
cp "${REPO_DIR}"/schemas/*.schema.json "${TMP_DIR}/schemas/"
cp "${REPO_DIR}/schemas/workflow-contract-consumers.json" "${TMP_DIR}/schemas/"
cp "${REPO_DIR}/docs/command-schemas.md" "${TMP_DIR}/docs/"
rm "${TMP_DIR}/schemas/command-review-output.schema.json"
assert_fails_with "missing registered schema fails visibly" \
  "command-review-output.schema.json: schema file is missing" \
  python3 "${HELPER}" \
    --repo-dir "${TMP_DIR}" \
    --schema-dir "${TMP_DIR}/schemas" \
    --registry "${TMP_DIR}/schemas/workflow-contract-consumers.json" \
    validate

TOTAL=$((TOTAL + 1))
if python3 - "${REPO_DIR}" >/dev/null <<'PY'; then
from pathlib import Path
import sys

repo = Path(sys.argv[1])
cross_review = (repo / ".claude/commands/vibeguard/cross-review.md").read_text(encoding="utf-8")
auto_optimize = (repo / "workflows/auto-optimize/SKILL.md").read_text(encoding="utf-8")

if "at most two total review rounds" not in cross_review:
    raise SystemExit("cross-review does not declare the two-round ceiling")
if "zero findings plus `APPROVED` stops immediately" not in cross_review:
    raise SystemExit("cross-review does not stop on a clean approved result")
for stale in ("up to 3 rounds", "after 3 rounds"):
    if stale in cross_review:
        raise SystemExit(f"cross-review retains stale loop marker: {stale}")

for stale in ("max_iterations:", "max_duration:", "./orchestrator --dir", "Create Runner environment"):
    if stale in auto_optimize:
        raise SystemExit(f"auto-optimize retains autonomous queue marker: {stale}")
if "select exactly one" not in auto_optimize or "Stop when the selected fix is verified" not in auto_optimize:
    raise SystemExit("auto-optimize does not enforce one bounded implementation")
PY
  printf '\033[32m  PASS: review and optimization workflows stay bounded\033[0m\n'
  PASS=$((PASS + 1))
else
  printf '\033[31m  FAIL: review and optimization workflows stay bounded\033[0m\n'
  FAIL=$((FAIL + 1))
fi

TOTAL=$((TOTAL + 1))
if python3 - "${REPO_DIR}" >/dev/null <<'PY'; then
from pathlib import Path
import sys

repo = Path(sys.argv[1])
command = (repo / ".claude/commands/vibeguard/exec-plan.md").read_text(encoding="utf-8")
installed_root = '${VIBEGUARD_DIR:-${HOME}/.vibeguard/installed}'
if command.count(installed_root) < 5:
    raise SystemExit("ExecPlan does not resolve its installed VibeGuard source in init/update/status")
if command.count('--rules-dir') != 3:
    raise SystemExit("ExecPlan does not pin the installed rules directory in all drift commands")
PY
  printf '\033[32m  PASS: ExecPlan drift checks resolve the installed guard and rules\033[0m\n'
  PASS=$((PASS + 1))
else
  printf '\033[31m  FAIL: ExecPlan drift checks resolve the installed guard and rules\033[0m\n'
  FAIL=$((FAIL + 1))
fi

printf '\nResults: %d passed, %d failed, %d total\n' "${PASS}" "${FAIL}" "${TOTAL}"
exit "${FAIL}"

#!/usr/bin/env bash
# Focused regression tests for required CI workflow coverage.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "${REPO_DIR}/.github/workflows/ci.yml" <<'PY'
from pathlib import Path
import re
import sys


workflow = Path(sys.argv[1]).read_text(encoding="utf-8")
job_match = re.search(
    r"(?ms)^  validate-and-test:\n(?P<body>.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)",
    workflow,
)
if job_match is None:
    raise SystemExit("missing validate-and-test job")
job = job_match.group(0)

required_job_lines = {
    "stable check name": "    name: CI (${{ matrix.os }})",
    "Ubuntu/macOS matrix": "        os: [ubuntu-latest, macos-latest]",
}
for description, line in required_job_lines.items():
    if line not in job.splitlines():
        raise SystemExit(f"validate-and-test missing {description}: {line}")

timeouts = re.findall(r"(?m)^    timeout-minutes: ([1-9][0-9]*)$", job)
if len(timeouts) != 1:
    raise SystemExit("validate-and-test needs exactly one finite positive timeout")
if re.search(r"(?m)^    continue-on-error:", job):
    raise SystemExit("validate-and-test must remain blocking")

required_steps = {
    "Setup regression tests": "bash tests/test_setup.sh",
    "Hook performance static analysis": "bash scripts/ci/validate-hook-perf.sh",
    "Hook performance contract regression tests": "bash tests/test_hook_perf_contract.sh",
    "Hook latency benchmark": "bash tests/bench_hook_latency.sh --runs=3 --confirmation-runs=3 --fail-on-regression",
}
for name, command in required_steps.items():
    marker = f"      - name: {name}"
    start = job.find(marker)
    if start < 0:
        raise SystemExit(f"missing required CI step: {name}")
    next_step = job.find("\n      - name:", start + len(marker))
    block = job[start:] if next_step < 0 else job[start:next_step]
    if command not in block:
        raise SystemExit(f"{name} does not run: {command}")
    if "continue-on-error" in block:
        raise SystemExit(f"{name} must remain blocking")
    if name == "Setup regression tests" and re.search(r"(?m)^\s+if:", block):
        raise SystemExit("setup regression tests must run on both matrix platforms")
PY

echo "CI workflow contract tests passed."

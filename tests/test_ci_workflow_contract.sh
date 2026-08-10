#!/usr/bin/env bash
# Focused regression tests for required CI workflow coverage.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "${REPO_DIR}/.github/workflows/ci.yml" <<'PY'
from pathlib import Path
import re
import sys


workflow = Path(sys.argv[1]).read_text(encoding="utf-8")


def job(name: str) -> str:
    match = re.search(
        rf"(?ms)^  {re.escape(name)}:\n.*?(?=^  [A-Za-z0-9_-]+:\n|\Z)",
        workflow,
    )
    if match is None:
        raise SystemExit(f"missing {name} job")
    return match.group(0)


def require_blocking_timeout(name: str, body: str) -> None:
    timeouts = re.findall(r"(?m)^    timeout-minutes: ([1-9][0-9]*)$", body)
    if len(timeouts) != 1:
        raise SystemExit(f"{name} needs exactly one finite positive timeout")
    if re.search(r"(?m)^    continue-on-error:", body):
        raise SystemExit(f"{name} must remain blocking")


core_job = job("validate-and-test")
for description, line in {
    "core check name": "    name: Core CI (${{ matrix.os }})",
    "Ubuntu/macOS matrix": "        os: [ubuntu-latest, macos-latest]",
}.items():
    if line not in core_job.splitlines():
        raise SystemExit(f"validate-and-test missing {description}: {line}")
require_blocking_timeout("validate-and-test", core_job)
if "bash tests/test_setup.sh" in core_job:
    raise SystemExit("validate-and-test must not serialize the full setup suite")

required_steps = {
    "Hook performance static analysis": "bash scripts/ci/validate-hook-perf.sh",
    "Hook performance contract regression tests": "bash tests/test_hook_perf_contract.sh",
    "Hook latency benchmark": "bash tests/bench_hook_latency.sh --runs=3 --confirmation-runs=3 --fail-on-regression",
}
for name, command in required_steps.items():
    marker = f"      - name: {name}"
    start = core_job.find(marker)
    if start < 0:
        raise SystemExit(f"missing required CI step: {name}")
    next_step = core_job.find("\n      - name:", start + len(marker))
    block = core_job[start:] if next_step < 0 else core_job[start:next_step]
    if command not in block:
        raise SystemExit(f"{name} does not run: {command}")
    if "continue-on-error" in block:
        raise SystemExit(f"{name} must remain blocking")

runtime_job = job("setup-runtime")
for description, line in {
    "Ubuntu/macOS matrix": "        os: [ubuntu-latest, macos-latest]",
    "runtime build": "        run: cargo build --manifest-path vibeguard-runtime/Cargo.toml",
    "per-OS artifact": "          name: setup-runtime-${{ matrix.os }}",
}.items():
    if line not in runtime_job.splitlines():
        raise SystemExit(f"setup-runtime missing {description}: {line}")
require_blocking_timeout("setup-runtime", runtime_job)

setup_job = job("setup-regressions")
for description, line in {
    "runtime fixture dependency": "    needs: setup-runtime",
    "Ubuntu/macOS matrix": "        os: [ubuntu-latest, macos-latest]",
    "complete shard matrix": "        shard: [bootstrap, install, protection, profile]",
    "per-OS artifact download": "          name: setup-runtime-${{ matrix.os }}",
    "prebuilt fixture selection": '          VIBEGUARD_TEST_PREBUILT_RUNTIME: "1"',
    "shard command": '        run: bash tests/test_setup.sh --shard "${{ matrix.shard }}"',
}.items():
    if line not in setup_job.splitlines():
        raise SystemExit(f"setup-regressions missing {description}: {line}")
require_blocking_timeout("setup-regressions", setup_job)

required_job = job("required-ci")
for description, line in {
    "stable protected check name": "    name: CI (${{ matrix.os }})",
    "Ubuntu/macOS matrix": "        os: [ubuntu-latest, macos-latest]",
    "core and setup dependencies": "    needs: [validate-and-test, setup-regressions]",
    "failure-safe execution": "    if: ${{ always() }}",
}.items():
    if line not in required_job.splitlines():
        raise SystemExit(f"required-ci missing {description}: {line}")
require_blocking_timeout("required-ci", required_job)
for result in ("needs.validate-and-test.result", "needs.setup-regressions.result"):
    if result not in required_job:
        raise SystemExit(f"required-ci does not enforce {result}")

benchmark_job = job("benchmark-report")
if "    needs: [validate-and-test, required-ci]" not in benchmark_job.splitlines():
    raise SystemExit("benchmark-report must wait for core and required CI")
PY

echo "CI workflow contract tests passed."

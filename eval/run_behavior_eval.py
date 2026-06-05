#!/usr/bin/env python3
"""Zero-cost behavior-level VibeGuard evaluation gate."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

from artifacts import (
    DEFAULT_RUNS_DIR,
    append_run_summary,
    build_run_dir,
    current_commit,
    utc_timestamp,
    write_run_artifacts,
)

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DATASET_PATH = REPO_ROOT / "eval" / "behavior" / "datasets" / "v1.jsonl"
DEFAULT_REQUIREMENTS_PATH = REPO_ROOT / "eval" / "behavior" / "requirements.json"
DEFAULT_THRESHOLDS_PATH = REPO_ROOT / "eval" / "behavior" / "thresholds.json"
SLICE_FIELDS = ("rule", "hook", "profile", "severity", "platform")
REQUIRED_SAMPLE_FIELDS = {
    "id",
    "description",
    "platform",
    "hook",
    "event",
    "profile",
    "severity",
    "rule",
    "runner",
    "script",
    "payload",
    "expect",
}
DEFAULT_THRESHOLDS = {
    "min_pass_rate": 100.0,
    "min_coverage_rate": 100.0,
    "slice_min_pass_rate": 100.0,
}


class BehaviorDatasetError(ValueError):
    """Raised when a behavior eval dataset cannot be trusted."""


def timeout_stream_text(value: str | bytes | None) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    return value


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    samples: list[dict[str, Any]] = []
    with path.open(encoding="utf-8") as f:
        for line_number, raw_line in enumerate(f, start=1):
            line = raw_line.strip()
            if not line:
                continue
            try:
                sample = json.loads(line)
            except json.JSONDecodeError as exc:
                raise BehaviorDatasetError(f"{path}:{line_number}: invalid JSON: {exc}") from exc
            validate_sample(sample, path, line_number)
            samples.append(sample)
    return samples


def validate_sample(sample: dict[str, Any], path: Path, line_number: int) -> None:
    missing = sorted(REQUIRED_SAMPLE_FIELDS - set(sample))
    if missing:
        raise BehaviorDatasetError(f"{path}:{line_number}: missing fields: {', '.join(missing)}")
    if sample["runner"] not in {"claude_hook", "codex_wrapper"}:
        raise BehaviorDatasetError(f"{path}:{line_number}: unsupported runner {sample['runner']!r}")
    if not isinstance(sample["payload"], dict):
        raise BehaviorDatasetError(f"{path}:{line_number}: payload must be an object")
    expect = sample["expect"]
    if not isinstance(expect, dict):
        raise BehaviorDatasetError(f"{path}:{line_number}: expect must be an object")
    if "json" in expect and not isinstance(expect["json"], list):
        raise BehaviorDatasetError(f"{path}:{line_number}: expect.json must be a list")
    for field in ("id", "platform", "hook", "profile", "severity", "rule"):
        if not isinstance(sample[field], str) or not sample[field].strip():
            raise BehaviorDatasetError(f"{path}:{line_number}: {field} must be a non-empty string")


def load_json_array(path: Path, *, name: str) -> list[dict[str, Any]]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise BehaviorDatasetError(f"{path}: invalid {name} JSON: {exc}") from exc
    if not isinstance(data, list):
        raise BehaviorDatasetError(f"{path}: {name} must be a list")
    for index, item in enumerate(data):
        if not isinstance(item, dict):
            raise BehaviorDatasetError(f"{path}: {name}[{index}] must be an object")
    return data


def load_thresholds(path: Path) -> dict[str, float]:
    if not path.exists():
        return dict(DEFAULT_THRESHOLDS)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise BehaviorDatasetError(f"{path}: invalid threshold JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise BehaviorDatasetError(f"{path}: thresholds must be an object")
    thresholds = dict(DEFAULT_THRESHOLDS)
    for key in DEFAULT_THRESHOLDS:
        if key not in data:
            continue
        value = data[key]
        if not isinstance(value, (int, float)) or value < 0 or value > 100:
            raise BehaviorDatasetError(f"{path}: {key} must be a number between 0 and 100")
        thresholds[key] = float(value)
    return thresholds


def sample_digest(samples: list[dict[str, Any]]) -> str:
    normalized = json.dumps(samples, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()


def evaluate_sample(sample: dict[str, Any], repo_root: Path, timeout_seconds: float) -> dict[str, Any]:
    started = time.time()
    with tempfile.TemporaryDirectory(prefix=f"vibeguard-behavior-{sample['id']}-") as tmp:
        tmp_path = Path(tmp)
        env = build_env(sample, repo_root, tmp_path)
        command = build_command(sample, repo_root)
        payload = json.dumps(sample["payload"], ensure_ascii=False)
        try:
            completed = subprocess.run(
                command,
                input=payload,
                cwd=repo_root,
                env=env,
                text=True,
                capture_output=True,
                timeout=timeout_seconds,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            return base_result(sample, started) | {
                "passed": False,
                "status": "fail",
                "error": f"timed out after {timeout_seconds:g}s",
                "stdout": timeout_stream_text(exc.stdout),
                "stderr": timeout_stream_text(exc.stderr),
                "checks": [{"name": "timeout", "passed": False}],
            }

    checks = evaluate_expectations(sample["expect"], completed.returncode, completed.stdout)
    passed = all(check["passed"] for check in checks)
    return base_result(sample, started) | {
        "passed": passed,
        "status": "pass" if passed else "fail",
        "exit_code": completed.returncode,
        "stdout": completed.stdout,
        "stderr": completed.stderr,
        "checks": checks,
    }


def build_command(sample: dict[str, Any], repo_root: Path) -> list[str]:
    script_path = repo_root / sample["script"]
    if sample["runner"] == "claude_hook":
        return ["bash", str(script_path)]
    if sample["runner"] == "codex_wrapper":
        return ["bash", str(script_path), sample["hook_name"]]
    raise BehaviorDatasetError(f"{sample['id']}: unsupported runner {sample['runner']!r}")


def build_env(sample: dict[str, Any], repo_root: Path, tmp_path: Path) -> dict[str, str]:
    env = os.environ.copy()
    log_dir = tmp_path / "logs"
    log_dir.mkdir()
    env["VIBEGUARD_LOG_DIR"] = str(log_dir)
    env["VIBEGUARD_SESSION_ID"] = sample["id"]
    env["PYTHONUTF8"] = "1"
    env["PYTHONIOENCODING"] = "utf-8"
    if sample["runner"] == "codex_wrapper":
        home = tmp_path / "home"
        repo_marker = home / ".vibeguard"
        repo_marker.mkdir(parents=True)
        (repo_marker / "repo-path").write_text(str(repo_root), encoding="utf-8")
        env["HOME"] = str(home)
    return env


def base_result(sample: dict[str, Any], started: float) -> dict[str, Any]:
    return {
        "id": sample["id"],
        "description": sample["description"],
        "platform": sample["platform"],
        "hook": sample["hook"],
        "event": sample["event"],
        "profile": sample["profile"],
        "severity": sample["severity"],
        "rule": sample["rule"],
        "latency_seconds": round(time.time() - started, 3),
    }


def evaluate_expectations(expect: dict[str, Any], exit_code: int, stdout: str) -> list[dict[str, Any]]:
    checks: list[dict[str, Any]] = []
    expected_exit = expect.get("exit_code", 0)
    checks.append({
        "name": "exit_code",
        "passed": exit_code == expected_exit,
        "expected": expected_exit,
        "actual": exit_code,
    })

    parsed_stdout: Any = None
    json_error = ""
    if expect.get("json"):
        try:
            parsed_stdout = json.loads(stdout)
        except json.JSONDecodeError as exc:
            json_error = str(exc)

    for assertion in expect.get("json", []):
        path = assertion["path"]
        actual = json_path(parsed_stdout, path) if parsed_stdout is not None else None
        expected = assertion.get("equals")
        checks.append({
            "name": f"json:{path}",
            "passed": actual == expected,
            "expected": expected,
            "actual": actual,
            "error": json_error,
        })

    for needle in expect.get("stdout_contains", []):
        checks.append({
            "name": f"stdout_contains:{needle}",
            "passed": needle in stdout,
            "expected": needle,
            "actual": stdout[:500],
        })
    return checks


def json_path(data: Any, path: str) -> Any:
    current = data
    for part in path.split("."):
        if not isinstance(current, dict) or part not in current:
            return None
        current = current[part]
    return current


def build_report(
    samples: list[dict[str, Any]],
    results: list[dict[str, Any]],
    requirements: list[dict[str, Any]],
    thresholds: dict[str, float],
    metadata: dict[str, Any],
) -> dict[str, Any]:
    total = len(results)
    passed = sum(1 for result in results if result["passed"])
    pass_rate = passed / total * 100 if total else 0.0
    coverage = coverage_report(samples, requirements)
    slices = slice_report(results)
    slice_failures = [
        {"dimension": dimension, "value": value, **stats}
        for dimension, values in slices.items()
        for value, stats in values.items()
        if stats["pass_rate"] < thresholds["slice_min_pass_rate"]
    ]
    failures = []
    if total == 0:
        failures.append("insufficient evidence: no behavior samples")
    if pass_rate < thresholds["min_pass_rate"]:
        failures.append(f"pass rate {pass_rate:.1f}% < threshold {thresholds['min_pass_rate']:.1f}%")
    if coverage["coverage_rate"] < thresholds["min_coverage_rate"]:
        failures.append(
            f"coverage rate {coverage['coverage_rate']:.1f}% < threshold "
            f"{thresholds['min_coverage_rate']:.1f}%"
        )
    if slice_failures:
        failures.append(f"{len(slice_failures)} slice(s) below {thresholds['slice_min_pass_rate']:.1f}%")

    behavior_score = pass_rate * (coverage["coverage_rate"] / 100)
    return {
        "metadata": metadata,
        "verdict": "fail" if failures else "pass",
        "failures": failures,
        "score": round(behavior_score, 1),
        "pass_rate": round(pass_rate, 1),
        "total": total,
        "passed": passed,
        "failed": total - passed,
        "coverage": coverage,
        "slices": slices,
        "slice_failures": slice_failures,
        "results": results,
    }


def build_behavior_summary(report: dict[str, Any], artifact_path: Path | str) -> dict[str, Any]:
    metadata = report["metadata"]
    result_path = Path(artifact_path)
    coverage = report.get("coverage", {})
    return {
        "schema_version": 1,
        "kind": "behavior",
        "score_type": "deterministic",
        "timestamp": utc_timestamp(),
        "run_id": result_path.parent.name,
        "artifact_path": str(result_path),
        "commit": metadata.get("commit", "unknown"),
        "dataset_source": metadata.get("dataset_source", ""),
        "dataset_digest": metadata.get("sample_digest", ""),
        "sample_count": report.get("total", metadata.get("sample_count", 0)),
        "scorer_version": metadata.get("scorer_version", ""),
        "verdict": report.get("verdict", "unknown"),
        "pass_rate": report.get("pass_rate", 0.0),
        "coverage_rate": coverage.get("coverage_rate", 0.0),
        "slice_failures": report.get("slice_failures", []),
        "failure_count": len(report.get("failures", [])),
    }


def coverage_report(samples: list[dict[str, Any]], requirements: list[dict[str, Any]]) -> dict[str, Any]:
    covered = []
    missing = []
    for requirement in requirements:
        if any(matches_requirement(sample, requirement) for sample in samples):
            covered.append(requirement)
        else:
            missing.append(requirement)
    required_total = len(requirements)
    coverage_rate = len(covered) / required_total * 100 if required_total else 100.0
    return {
        "required_total": required_total,
        "covered_total": len(covered),
        "coverage_rate": round(coverage_rate, 1),
        "missing": missing,
    }


def matches_requirement(sample: dict[str, Any], requirement: dict[str, Any]) -> bool:
    return all(sample.get(key) == value for key, value in requirement.items())


def slice_report(results: list[dict[str, Any]]) -> dict[str, dict[str, dict[str, Any]]]:
    report: dict[str, dict[str, dict[str, Any]]] = {}
    for field in SLICE_FIELDS:
        field_report: dict[str, dict[str, Any]] = {}
        for result in results:
            value = str(result.get(field, "unknown"))
            stats = field_report.setdefault(value, {"total": 0, "passed": 0, "failed_ids": []})
            stats["total"] += 1
            if result["passed"]:
                stats["passed"] += 1
            else:
                stats["failed_ids"].append(result["id"])
        for stats in field_report.values():
            stats["failed"] = stats["total"] - stats["passed"]
            stats["pass_rate"] = round(stats["passed"] / stats["total"] * 100 if stats["total"] else 0, 1)
        report[field] = field_report
    return report


def run_model_gate(args: argparse.Namespace) -> dict[str, Any]:
    command = [
        sys.executable,
        str(REPO_ROOT / "eval" / "run_eval.py"),
        "--model",
        args.model,
        "--artifact-root",
        args.artifact_root,
    ]
    if args.model_rules:
        command.extend(["--rules", args.model_rules])
    completed = subprocess.run(
        command,
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    result_path = ""
    for line in completed.stdout.splitlines():
        if "Result saved: " in line:
            result_path = line.split("Result saved: ", 1)[1].strip()
    return {
        "enabled": True,
        "command": command,
        "exit_code": completed.returncode,
        "result_path": result_path,
        "stdout_tail": completed.stdout[-1000:],
        "stderr_tail": completed.stderr[-1000:],
    }


def print_text_report(report: dict[str, Any]) -> None:
    print("====== VibeGuard Behavior Eval ======")
    print(f"Behavior gate: {report['verdict']}")
    print(f"Score: {report['score']}")
    print(f"Samples: {report['passed']}/{report['total']} passed ({report['pass_rate']}%)")
    coverage = report["coverage"]
    print(
        f"Coverage: {coverage['covered_total']}/{coverage['required_total']} "
        f"required slices ({coverage['coverage_rate']}%)"
    )
    if coverage["missing"]:
        print("Missing coverage:")
        for item in coverage["missing"]:
            print("  " + json.dumps(item, ensure_ascii=False, sort_keys=True))
    if report["failures"]:
        print("Failures:")
        for failure in report["failures"]:
            print(f"  {failure}")
    print("Slices:")
    for dimension in SLICE_FIELDS:
        values = report["slices"].get(dimension, {})
        rendered = ", ".join(
            f"{value}={stats['passed']}/{stats['total']}"
            for value, stats in sorted(values.items())
        )
        print(f"  {dimension}: {rendered or 'insufficient evidence'}")
    artifact_path = report["metadata"].get("artifact_path")
    if artifact_path:
        print(f"Result saved: {artifact_path}")
    print("====================================")


def run_behavior_eval(args: argparse.Namespace) -> int:
    dataset_path = Path(args.dataset).resolve()
    requirements_path = Path(args.requirements).resolve()
    thresholds_path = Path(args.thresholds).resolve()
    try:
        samples = load_jsonl(dataset_path)
        requirements = load_json_array(requirements_path, name="coverage requirements")
        thresholds = load_thresholds(thresholds_path)
    except BehaviorDatasetError as exc:
        print(f"Invalid behavior eval config: {exc}", file=sys.stderr)
        return 2

    digest = sample_digest(samples)
    metadata = {
        "dataset_source": str(dataset_path),
        "sample_digest": digest,
        "sample_count": len(samples),
        "requirements_source": str(requirements_path),
        "required_slice_count": len(requirements),
        "thresholds_source": str(thresholds_path),
        "thresholds": thresholds,
        "commit": current_commit(short=False),
        "scorer_version": "behavior-e2e-v1",
    }

    if args.dry_run:
        if args.json:
            print(json.dumps({"metadata": metadata, "samples": samples}, indent=2, ensure_ascii=False))
        else:
            print(f"Behavior dataset source: {dataset_path}")
            print(f"Behavior sample count: {len(samples)}")
            print(f"Behavior sample digest: {digest}")
            print(f"Required coverage source: {requirements_path}")
            print(f"Required coverage count: {len(requirements)}")
            print(f"Threshold source: {thresholds_path}")
            for sample in samples:
                print(
                    f"  [{sample['platform']}/{sample['hook']}/{sample['severity']}] "
                    f"{sample['id']}: {sample['description']}"
                )
        return 0

    results = [evaluate_sample(sample, REPO_ROOT, args.timeout) for sample in samples]
    report = build_report(samples, results, requirements, thresholds, metadata)
    if args.model_gate:
        model_gate = run_model_gate(args)
        report["model_gate"] = model_gate
        if model_gate["exit_code"] != 0:
            report["verdict"] = "fail"
            report["failures"].append(f"model gate failed with exit code {model_gate['exit_code']}")

    if not args.no_artifacts:
        run_dir = build_run_dir(args.artifact_root)
        artifact_path = write_run_artifacts(
            run_dir,
            metadata=report["metadata"],
            samples=samples,
            results=results,
        )
        report["metadata"]["artifact_path"] = str(artifact_path)
        index_path = append_run_summary(
            args.artifact_root,
            build_behavior_summary(report, artifact_path),
        )
        report["metadata"]["index_path"] = str(index_path)

    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False, sort_keys=True))
    else:
        print_text_report(report)

    if args.fail_on_threshold and report["verdict"] != "pass":
        return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Run zero-cost VibeGuard behavior evals")
    parser.add_argument("--dataset", default=str(DEFAULT_DATASET_PATH))
    parser.add_argument("--requirements", default=str(DEFAULT_REQUIREMENTS_PATH))
    parser.add_argument("--thresholds", default=str(DEFAULT_THRESHOLDS_PATH))
    parser.add_argument("--artifact-root", default=str(DEFAULT_RUNS_DIR))
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--fail-on-threshold", action="store_true")
    parser.add_argument("--no-artifacts", action="store_true")
    parser.add_argument("--model-gate", action="store_true", help="also run eval/run_eval.py for manual/API-backed gates")
    parser.add_argument("--model", default="haiku")
    parser.add_argument("--model-rules", help="optional rule prefix for the model-backed gate")
    return run_behavior_eval(parser.parse_args())


if __name__ == "__main__":
    raise SystemExit(main())

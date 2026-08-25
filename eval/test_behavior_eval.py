#!/usr/bin/env python3
"""Tests for behavior-level eval reporting."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import run_behavior_eval


class BehaviorEvalTest(unittest.TestCase):
    def test_dataset_loader_validates_required_fields(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "behavior.jsonl"
            path.write_text('{"id": "missing"}\n', encoding="utf-8")

            with self.assertRaises(run_behavior_eval.BehaviorDatasetError):
                run_behavior_eval.load_jsonl(path)

    def test_json_expectations_check_nested_paths(self) -> None:
        stdout = json.dumps({
            "hookSpecificOutput": {
                "permissionDecision": "deny",
                "permissionDecisionReason": "blocked",
            }
        })

        checks = run_behavior_eval.evaluate_expectations(
            {
                "exit_code": 0,
                "json": [{"path": "hookSpecificOutput.permissionDecision", "equals": "deny"}],
                "stdout_contains": ["blocked"],
            },
            0,
            stdout,
        )

        self.assertTrue(all(check["passed"] for check in checks))

    def test_stdout_empty_expectation_passes_on_silent_allow(self) -> None:
        checks = run_behavior_eval.evaluate_expectations(
            {"exit_code": 0, "stdout_empty": True},
            0,
            "",
        )

        self.assertTrue(all(check["passed"] for check in checks))

    def test_stdout_empty_expectation_fails_when_hook_emits_output(self) -> None:
        stdout = json.dumps({"decision": "block", "reason": "denied"})

        checks = run_behavior_eval.evaluate_expectations(
            {"exit_code": 0, "stdout_empty": True},
            0,
            stdout,
        )

        empty_check = next(check for check in checks if check["name"] == "stdout_empty")
        self.assertFalse(empty_check["passed"])
        self.assertEqual(empty_check["actual"], stdout)

    def test_evidence_kind_distinguishes_intercepts_and_allows(self) -> None:
        self.assertEqual(
            run_behavior_eval.evidence_kind(
                {"runner": "claude_hook", "expect": {"json": [{"equals": "block"}]}}
            ),
            "intercept",
        )
        self.assertEqual(
            run_behavior_eval.evidence_kind(
                {"runner": "guard", "expect": {"exit_code": 0}}
            ),
            "allow",
        )

    def test_evidence_kind_ignores_structured_json_values_for_classification(self) -> None:
        self.assertEqual(
            run_behavior_eval.evidence_kind({
                "runner": "guard",
                "expect": {
                    "exit_code": 0,
                    "json": [{"equals": []}, {"equals": {"status": "pass"}}],
                },
            }),
            "allow",
        )

    def test_evidence_kind_rejects_error_exit_as_intercept_evidence(self) -> None:
        self.assertEqual(
            run_behavior_eval.evidence_kind(
                {"runner": "guard", "expect": {"exit_code": 1}}
            ),
            "intercept",
        )
        self.assertEqual(
            run_behavior_eval.evidence_kind(
                {"runner": "guard", "expect": {"exit_code": 2}}
            ),
            "unknown",
        )
        self.assertEqual(
            run_behavior_eval.evidence_kind(
                {"runner": "claude_hook", "expect": {"exit_code": 1}}
            ),
            "unknown",
        )

    def test_coverage_can_require_balanced_evidence(self) -> None:
        requirement = {
            "platform": "runtime",
            "rule": "RS-03",
            "evidence": ["intercept", "allow"],
        }
        positive = {
            "platform": "runtime",
            "rule": "RS-03",
            "runner": "guard",
            "expect": {"exit_code": 1},
        }
        negative = positive | {"expect": {"exit_code": 0}}

        self.assertFalse(run_behavior_eval.requirement_is_covered([positive], requirement))
        self.assertTrue(
            run_behavior_eval.requirement_is_covered([positive, negative], requirement)
        )

    def test_requirement_validation_rejects_unknown_evidence(self) -> None:
        with self.assertRaises(run_behavior_eval.BehaviorDatasetError):
            run_behavior_eval.validate_requirements(
                [{"platform": "runtime", "evidence": ["intercept", "unknown"]}],
                Path("requirements.json"),
            )

    def test_timeout_stream_text_decodes_bytes(self) -> None:
        self.assertEqual(run_behavior_eval.timeout_stream_text(b"partial\n"), "partial\n")
        self.assertEqual(run_behavior_eval.timeout_stream_text(None), "")

    def test_guard_fixture_runner_materializes_files_and_builds_command(self) -> None:
        sample = {
            "id": "guard-sample",
            "runner": "guard",
            "script": "guards/rust/check_unwrap_in_prod.sh",
            "payload": {
                "files": {"src/main.rs": "fn main() {}\n"},
                "args": ["--strict"],
            },
        }

        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            repo_root = tmp_path / "repo"
            repo_root.mkdir()
            fixture_root = run_behavior_eval.materialize_guard_fixture(sample, tmp_path)
            command = run_behavior_eval.build_command(sample, repo_root, fixture_root)

            self.assertEqual(
                (fixture_root / "src/main.rs").read_text(encoding="utf-8"),
                "fn main() {}\n",
            )
            self.assertEqual(command[-2:], ["--strict", str(fixture_root)])
            self.assertEqual(
                run_behavior_eval.guard_runtime_target(sample),
                ("rust", "unwrap-in-prod"),
            )

    def test_guard_fixture_rejects_parent_traversal(self) -> None:
        sample = {
            "id": "guard-traversal",
            "runner": "guard",
            "payload": {"files": {"../outside.rs": "fn main() {}\n"}},
        }
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(run_behavior_eval.BehaviorDatasetError):
                run_behavior_eval.materialize_guard_fixture(sample, Path(tmp))

    def test_guard_env_skips_release_runtime_without_scan_support(self) -> None:
        sample = {"id": "guard-runtime", "runner": "guard"}
        with tempfile.TemporaryDirectory() as tmp:
            repo_root = Path(tmp) / "repo"
            release = repo_root / "vibeguard-runtime/target/release/vibeguard-runtime"
            debug = repo_root / "vibeguard-runtime/target/debug/vibeguard-runtime"
            release.parent.mkdir(parents=True)
            debug.parent.mkdir(parents=True)
            release.write_text("release", encoding="utf-8")
            debug.write_text("debug", encoding="utf-8")
            def probe(command: list[str], **_: object) -> subprocess.CompletedProcess[str]:
                usage = "  scan  <language> <rule>\n" if Path(command[0]) == debug else "old runtime\n"
                return subprocess.CompletedProcess(command, 1, "", usage)

            with patch("run_behavior_eval.os.access", return_value=True), patch(
                "run_behavior_eval.subprocess.run", side_effect=probe
            ):
                env = run_behavior_eval.build_env(sample, repo_root, Path(tmp))
            self.assertEqual(env["VIBEGUARD_RUNTIME"], str(debug))

    def test_missing_required_coverage_reduces_score_and_fails(self) -> None:
        samples = [
            {
                "id": "covered",
                "rule": "L7",
                "hook": "pre-bash-guard",
                "profile": "default",
                "severity": "critical",
                "platform": "claude",
            }
        ]
        results = [
            {
                "id": "covered",
                "rule": "L7",
                "hook": "pre-bash-guard",
                "profile": "default",
                "severity": "critical",
                "platform": "claude",
                "passed": True,
            }
        ]
        requirements = [
            {"platform": "claude", "hook": "pre-bash-guard"},
            {"platform": "codex", "hook": "pre-bash-guard"},
        ]

        report = run_behavior_eval.build_report(
            samples,
            results,
            requirements,
            {
                "min_pass_rate": 100.0,
                "min_coverage_rate": 100.0,
                "slice_min_pass_rate": 100.0,
            },
            metadata={},
        )

        self.assertEqual(report["verdict"], "fail")
        self.assertEqual(report["coverage"]["coverage_rate"], 50.0)
        self.assertEqual(report["score"], 50.0)
        self.assertEqual(report["coverage"]["missing"], [{"platform": "codex", "hook": "pre-bash-guard"}])

    def test_behavior_summary_contains_required_observability_fields(self) -> None:
        report = {
            "metadata": {
                "commit": "abc123",
                "dataset_source": "/repo/eval/behavior/datasets/v1.jsonl",
                "sample_digest": "digest123",
                "sample_count": 2,
                "scorer_version": "behavior-e2e-v1",
            },
            "verdict": "fail",
            "pass_rate": 50.0,
            "total": 2,
            "coverage": {"coverage_rate": 75.0},
            "slice_failures": [{"dimension": "rule", "value": "L1"}],
            "failures": ["one failure"],
        }

        summary = run_behavior_eval.build_behavior_summary(
            report,
            Path("/tmp/eval/runs/20260101T000000Z-abc123/results.json"),
        )

        self.assertEqual(summary["kind"], "behavior")
        self.assertEqual(summary["score_type"], "deterministic")
        self.assertEqual(summary["commit"], "abc123")
        self.assertEqual(summary["dataset_digest"], "digest123")
        self.assertEqual(summary["pass_rate"], 50.0)
        self.assertEqual(summary["coverage_rate"], 75.0)
        self.assertEqual(summary["slice_failures"], [{"dimension": "rule", "value": "L1"}])

    def test_codex_wrapper_env_uses_dev_linked_execution_mode(self) -> None:
        sample = {"id": "codex-sample", "runner": "codex_wrapper"}

        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            repo_root = tmp_path / "repo"
            repo_root.mkdir()

            env = run_behavior_eval.build_env(sample, repo_root, tmp_path)
            vibeguard_home = Path(env["HOME"]) / ".vibeguard"

            self.assertEqual((vibeguard_home / "repo-path").read_text(encoding="utf-8"), str(repo_root))
            self.assertEqual(
                (vibeguard_home / "execution-mode").read_text(encoding="utf-8"),
                "dev-linked-repo\n",
            )

    def test_model_gate_resolves_behavior_artifact_root_before_child_cwd(self) -> None:
        args = argparse.Namespace(
            model="haiku",
            model_rules=None,
            artifact_root="custom-runs",
        )

        original_cwd = Path.cwd()
        with tempfile.TemporaryDirectory() as tmp, patch("run_behavior_eval.subprocess.run") as run:
            expected_root = str((Path(tmp) / "custom-runs").resolve())
            os.chdir(tmp)
            try:
                run.return_value = subprocess.CompletedProcess(
                    args=[],
                    returncode=0,
                    stdout=f"Result saved: {expected_root}/model/results.json\n",
                    stderr="",
                )
                result = run_behavior_eval.run_model_gate(args)
            finally:
                os.chdir(original_cwd)

        command = run.call_args.args[0]
        self.assertIn("--artifact-root", command)
        self.assertEqual(command[command.index("--artifact-root") + 1], expected_root)
        self.assertEqual(result["result_path"], f"{expected_root}/model/results.json")


if __name__ == "__main__":
    unittest.main()

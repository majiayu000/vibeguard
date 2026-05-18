#!/usr/bin/env python3
"""Tests for behavior-level eval reporting."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

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


if __name__ == "__main__":
    unittest.main()

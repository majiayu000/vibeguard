#!/usr/bin/env python3
"""Real-execution flow tests (producer runs, provenance, interruption) for the paired eval gate."""

from __future__ import annotations

import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import paired_execution as execution  # noqa: E402
from paired_test_support import sequence_client  # noqa: E402

class RealExecutionTest(unittest.TestCase):
    def test_non_target_producer_uses_an_ordinary_task_contract(self) -> None:
        client = sequence_client(["plain answer"])
        sample = {
            "id": "n1",
            "task": "Explain a value",
            "input": "42",
            "rubric": "Be correct",
        }

        result = execution.evaluate_non_target_sample(
            client,
            "producer-model",
            execution.build_non_target_system_prompt("loaded rules"),
            sample,
        )

        self.assertEqual(result["response"], "plain answer")
        request = client.messages.create.call_args.kwargs
        self.assertIn("ordinary task", request["system"])
        self.assertNotIn('"detected"', request["system"])
        self.assertEqual(request["messages"][0]["content"], "Task: Explain a value\n\nInput:\n42")

    def test_non_target_producer_treats_empty_reply_as_skipped(self) -> None:
        result = execution.evaluate_non_target_sample(
            sequence_client(["   "]),
            "producer-model",
            execution.build_non_target_system_prompt("loaded rules"),
            {
                "id": "n1",
                "task": "Answer",
                "input": "x",
                "rubric": "Be correct",
            },
        )

        self.assertTrue(result["skipped"])
        self.assertIn("empty", result["error"])

    def test_artifact_destination_is_reserved_before_model_calls(self) -> None:
        client = Mock()
        anthropic_module = types.SimpleNamespace(Anthropic=lambda: client)
        with tempfile.TemporaryDirectory() as tmp:
            artifact_root = Path(tmp) / "not-a-directory"
            artifact_root.write_text("occupied", encoding="utf-8")
            with patch.dict(sys.modules, {"anthropic": anthropic_module}):
                with self.assertRaisesRegex(
                    execution.PairedExecutionError, "artifact"
                ):
                    execution.execute_real_run(
                        producer_model="producer-model",
                        judge_model="judge-model",
                        candidate="U-01",
                        with_rules="with",
                        without_rules="without",
                        target_samples=[],
                        non_target_samples=[],
                        identities={},
                        thresholds={
                            "min_target_samples": 5,
                            "min_non_target_samples": 30,
                            "min_target_delta": 0.0,
                            "max_non_target_drop": 0.0,
                            "max_skip_rate": 0.1,
                            "max_skip_delta": 0.05,
                            "max_cross_refs": 4,
                            "calibrated": True,
                        },
                        removal_evidence={},
                        cross_refs_exceeded=False,
                        artifact_root=artifact_root,
                    )

        self.assertEqual(client.messages.create.call_count, 0)

    def test_real_uncalibrated_run_writes_auditable_report_and_fails_closed(self) -> None:
        target_samples = [
            {
                "id": f"target-{index}",
                "rule": "U-01",
                "severity": "high",
                "lang": "python",
                "input": "print('x')",
                "code": "print('x')",
                "description": "target",
                "expected_action": "warn_or_refuse",
            }
            for index in range(5)
        ]
        non_target_samples = [
            {
                "id": f"non-target-{index}",
                "task": "Answer",
                "input": str(index),
                "rubric": "Be correct",
            }
            for index in range(30)
        ]
        target_with = json.dumps({
            "detected": True,
            "rule_ids": ["U-01"],
            "confidence": "high",
            "reason": "caught",
        })
        target_without = json.dumps({
            "detected": False,
            "rule_ids": [],
            "confidence": "high",
            "reason": "not caught",
        })
        replies = (
            [reply for index in range(5) for reply in
             ((target_with, target_without) if index % 2 == 0
              else (target_without, target_with))]
            + [f"with response {index}" for index in range(30)]
            + [f"without response {index}" for index in range(30)]
            + [
                json.dumps({"winner": "tie", "reason": "equivalent"})
                for _ in range(60)
            ]
        )
        client = sequence_client(replies)
        anthropic_module = types.SimpleNamespace(Anthropic=lambda: client)
        thresholds = {
            "min_target_samples": 5,
            "min_non_target_samples": 30,
            "min_target_delta": 0.0,
            "max_non_target_drop": 0.0,
            "max_skip_rate": 0.1,
            "max_skip_delta": 0.05,
            "max_cross_refs": 4,
            "calibrated": False,
        }
        identity_base = {
            "model": "producer-model",
            "dataset_digest": "dataset",
            "sample_set_digest": "samples",
        }
        evidence = {
            "candidate_file": "common/example.md",
            "assertions": {
                "file_set": "pass",
                "presence": "pass",
                "definition_site": "pass",
                "file_diff": "pass",
                "definition_count": "pass",
            },
            "failed_assertions": [],
            "cross_references": [],
            "empty_shells": [],
            "definition_count_with": 127,
            "definition_count_without": 126,
            "removed_section_characters": 100,
        }

        pinned_commit = "a" * 40
        with (
            tempfile.TemporaryDirectory() as tmp,
            patch.dict(sys.modules, {"anthropic": anthropic_module}),
            patch.object(
                execution, "current_commit", return_value=pinned_commit
            ) as commit_mock,
        ):
            exit_code = execution.execute_real_run(
                producer_model="producer-model",
                judge_model="judge-model",
                candidate="U-01",
                with_rules="rules with candidate",
                without_rules="rules without candidate",
                target_samples=target_samples,
                non_target_samples=non_target_samples,
                identities={
                    "target_with": {**identity_base, "rule_digest": "with"},
                    "target_without": {**identity_base, "rule_digest": "without"},
                    "non_target_with": {**identity_base, "rule_digest": "with"},
                    "non_target_without": {**identity_base, "rule_digest": "without"},
                },
                thresholds=thresholds,
                removal_evidence=evidence,
                cross_refs_exceeded=False,
                artifact_root=Path(tmp),
            )
            reports = list(Path(tmp).glob("*/report.json"))
            self.assertEqual(len(reports), 1)
            report = json.loads(reports[0].read_text(encoding="utf-8"))

        commit_mock.assert_called_once_with(short=False)
        self.assertEqual(exit_code, 1)
        self.assertEqual(report["commit"], pinned_commit)
        self.assertEqual(report["overall"]["verdict"], "inconclusive")
        self.assertEqual(report["target_axis"]["target_delta"], 1.0)
        self.assertEqual(report["non_target_axis"]["quality_delta"], 0.0)
        self.assertEqual(report["producer_model"], "producer-model")
        self.assertEqual(report["judge_model"], "judge-model")
        self.assertEqual(report["producer_schedule"]["non_target"][:2], [{"id": "non-target-0", "first_arm": "with"}, {"id": "non-target-1", "first_arm": "without"}])
        self.assertEqual(len(report["judge_prompt_digest"]), 64)
        self.assertEqual(
            report["non_target_results"]["judge"][0]["mapped_outcomes"],
            ["tie", "tie"],
        )
    def test_keyboard_interrupt_writes_partial_report_and_stops_new_calls(self) -> None:
        target_samples = [
            {
                "id": f"target-{index}",
                "rule": "U-01",
                "severity": "high",
                "lang": "python",
                "input": "print('x')",
                "code": "print('x')",
                "description": "target",
                "expected_action": "warn_or_refuse",
            }
            for index in range(5)
        ]
        non_target_samples = [
            {
                "id": f"non-target-{index}",
                "task": "Answer",
                "input": str(index),
                "rubric": "Be correct",
            }
            for index in range(30)
        ]
        target_reply = json.dumps({
            "detected": True,
            "rule_ids": ["U-01"],
            "confidence": "high",
            "reason": "caught",
        })
        client = Mock()
        client.messages.create.side_effect = (
            [
                type(
                    "Response",
                    (),
                    {"content": [type("Block", (), {"text": target_reply})()]},
                )()
                for _ in range(10)
            ]
            + [
                type(
                    "Response",
                    (),
                    {"content": [type("Block", (), {"text": "paid partial"})()]},
                )(),
                KeyboardInterrupt(),
            ]
        )
        anthropic_module = types.SimpleNamespace(Anthropic=lambda: client)
        thresholds = {
            "min_target_samples": 5,
            "min_non_target_samples": 30,
            "min_target_delta": 0.0,
            "max_non_target_drop": 0.0,
            "max_skip_rate": 0.1,
            "max_skip_delta": 0.05,
            "max_cross_refs": 4,
            "calibrated": True,
        }
        identity_base = {
            "model": "producer-model",
            "dataset_digest": "dataset",
            "sample_set_digest": "samples",
        }
        evidence = {
            "candidate_file": "common/example.md",
            "assertions": {
                "file_set": "pass",
                "presence": "pass",
                "definition_site": "pass",
                "file_diff": "pass",
                "definition_count": "pass",
            },
            "failed_assertions": [],
            "cross_references": [],
            "empty_shells": [],
            "definition_count_with": 127,
            "definition_count_without": 126,
            "removed_section_characters": 100,
        }

        with tempfile.TemporaryDirectory() as tmp, patch.dict(
            sys.modules, {"anthropic": anthropic_module}
        ):
            exit_code = execution.execute_real_run(
                producer_model="producer-model",
                judge_model="judge-model",
                candidate="U-01",
                with_rules="rules with candidate",
                without_rules="rules without candidate",
                target_samples=target_samples,
                non_target_samples=non_target_samples,
                identities={
                    "target_with": {**identity_base, "rule_digest": "with"},
                    "target_without": {**identity_base, "rule_digest": "without"},
                    "non_target_with": {**identity_base, "rule_digest": "with"},
                    "non_target_without": {**identity_base, "rule_digest": "without"},
                },
                thresholds=thresholds,
                removal_evidence=evidence,
                cross_refs_exceeded=False,
                artifact_root=Path(tmp),
            )
            report_path = next(Path(tmp).glob("*/report.json"))
            report = json.loads(report_path.read_text(encoding="utf-8"))

        self.assertEqual(exit_code, 1)
        self.assertTrue(report["interrupted"])
        self.assertEqual(report["interruption_stage"], "non_target_without")
        self.assertEqual(report["overall"]["verdict"], "inconclusive")
        self.assertEqual(report["non_target_results"]["with"][0]["response"], "paid partial")
        self.assertTrue(report["non_target_results"]["with"][1]["skipped"])
        self.assertTrue(all(
            result["skipped"] for result in report["non_target_results"]["without"]
        ))
        self.assertEqual(client.messages.create.call_count, 12)

if __name__ == "__main__":
    unittest.main()

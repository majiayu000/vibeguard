#!/usr/bin/env python3
"""Judge mapping and verdict conjunction tests for the paired eval gate."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run_paired_eval as paired  # noqa: E402
from paired_test_support import sequence_client  # noqa: E402

class JudgeAndVerdictTest(unittest.TestCase):
    def setUp(self) -> None:
        self.thresholds = {
            "min_target_samples": 5,
            "min_non_target_samples": 30,
            "min_target_delta": 0.0,
            "max_non_target_drop": 0.0,
            "max_skip_rate": 0.1,
            "max_skip_delta": 0.05,
            "max_cross_refs": 4,
            "calibrated": True,
        }

    def test_pairwise_parser_and_swapped_mapping_are_strict(self) -> None:
        verdict = paired.parse_pairwise_judge('{"winner":"A","reason":"clearer"}')
        self.assertEqual(verdict["winner"], "A")
        for bad in (
            '{"winner":"with","reason":"leaks label"}',
            '{"winner":"A"}',
            "A",
        ):
            with self.subTest(bad=bad), self.assertRaises(paired.PairwiseJudgeError):
                paired.parse_pairwise_judge(bad)

        result = paired.judge_pair(
            sequence_client([
                '{"winner":"A","reason":"better"}',
                '{"winner":"B","reason":"better"}',
            ]),
            "judge-model",
            {"id": "n1", "task": "answer", "input": "x", "rubric": "correct"},
            "with output",
            "without output",
        )
        self.assertEqual(result["outcome"], "with_win")
        self.assertEqual(result["mapped_outcomes"], ["with_win", "with_win"])
        self.assertEqual(len(result["raw_judge_responses"]), 2)

    def test_swapped_conflict_makes_non_target_inconclusive(self) -> None:
        result = paired.judge_pair(
            sequence_client([
                '{"winner":"A","reason":"first"}',
                '{"winner":"A","reason":"position"}',
            ]),
            "judge-model",
            {"id": "n1", "task": "answer", "input": "x", "rubric": "correct"},
            "with output",
            "without output",
        )
        self.assertEqual(result["outcome"], "conflict")

        axis = paired.compute_non_target_axis([result] * 30, 30, self.thresholds)
        self.assertEqual(axis["verdict"], "inconclusive")
        self.assertIn("judge conflict", " ".join(axis["reasons"]))

    def test_judge_interrupt_preserves_the_completed_paid_response(self) -> None:
        client = Mock()
        client.messages.create.side_effect = [
            type(
                "Response",
                (),
                {
                    "content": [
                        type(
                            "Block",
                            (),
                            {"text": '{"winner":"A","reason":"better"}'},
                        )()
                    ]
                },
            )(),
            KeyboardInterrupt(),
        ]

        result = paired.judge_pair(
            client,
            "judge-model",
            {"id": "n1", "task": "answer", "input": "x", "rubric": "correct"},
            "with output",
            "without output",
        )

        self.assertTrue(result["interrupted"])
        self.assertTrue(result["skipped"])
        self.assertEqual(len(result["raw_judge_responses"]), 1)
        self.assertEqual(result["mapped_outcomes"], ["with_win"])
        self.assertEqual(client.messages.create.call_count, 2)

    def test_malformed_judge_response_is_preserved_for_audit(self) -> None:
        result = paired.judge_pair(
            sequence_client(['{"winner":"A","winner":"B","reason":"duplicate"}']),
            "judge-model",
            {"id": "n1", "task": "answer", "input": "x", "rubric": "correct"},
            "with output",
            "without output",
        )

        self.assertTrue(result["skipped"])
        self.assertEqual(result["raw_judge_responses"], ['{"winner":"A","winner":"B","reason":"duplicate"}'])
        self.assertIn("duplicate JSON key", result["error"])

    def test_requested_sample_count_remains_the_denominator(self) -> None:
        with_results = [{"detected": True}] * 4 + [{"skipped": True}]
        without_results = [{"detected": False}] * 5
        axis = paired.compute_target_axis(with_results, without_results, 5, self.thresholds)

        self.assertEqual(axis["with_pass_rate"], 0.8)
        self.assertEqual(axis["without_pass_rate"], 0.0)
        self.assertEqual(axis["with_skip_rate"], 0.2)
        self.assertEqual(axis["verdict"], "inconclusive")

    def test_overall_is_conjunctive_and_uncalibrated_never_passes(self) -> None:
        self.assertEqual(
            paired.compute_overall_verdict(
                {"verdict": "pass"}, {"verdict": "fail"}, self.thresholds, False
            )["verdict"],
            "fail",
        )
        self.assertEqual(
            paired.compute_overall_verdict(
                {"verdict": "pass"}, {"verdict": "pass"}, self.thresholds, False
            )["verdict"],
            "pass",
        )
        uncalibrated = {**self.thresholds, "calibrated": False}
        result = paired.compute_overall_verdict(
            {"verdict": "pass"}, {"verdict": "pass"}, uncalibrated, False
        )
        self.assertEqual(result["verdict"], "inconclusive")
        self.assertNotEqual(paired.real_run_exit_code(result["verdict"]), 0)

if __name__ == "__main__":
    unittest.main()

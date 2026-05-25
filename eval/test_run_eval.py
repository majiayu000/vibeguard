#!/usr/bin/env python3
"""Tests for eval error accounting."""

from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run_eval  # noqa: E402


class FailingMessages:
    def create(self, **_kwargs):
        raise RuntimeError("network unavailable")


class FailingClient:
    messages = FailingMessages()


class TextBlock:
    def __init__(self, text: str):
        self.text = text


class StaticMessages:
    def __init__(self, reply: str):
        self.reply = reply

    def create(self, **_kwargs):
        return type("Response", (), {"content": [TextBlock(self.reply)]})()


class StaticClient:
    def __init__(self, reply: str):
        self.messages = StaticMessages(reply)


class EvalErrorAccountingTest(unittest.TestCase):
    def test_api_error_returns_skipped_not_missed(self) -> None:
        sample = {
            "rule": "SEC-01",
            "severity": "critical",
            "lang": "python",
            "code": "print('x')",
            "description": "sample failure",
        }

        result = run_eval.evaluate_sample(FailingClient(), "model", "rules", sample)

        self.assertTrue(result["skipped"])
        self.assertEqual(result["rule"], "SEC-01")
        self.assertNotIn("detected", result)
        self.assertIn("network unavailable", result["error"])

    def test_report_excludes_skipped_from_denominators(self) -> None:
        results = [
            {
                "rule": "SEC-01",
                "severity": "critical",
                "detected": True,
                "response": "ok",
                "description": "detected sample",
            },
            {
                "rule": "SEC-02",
                "severity": "critical",
                "skipped": True,
                "error": "network unavailable",
                "response": "",
                "description": "skipped sample",
            },
            {
                "rule": "FP-CHECK",
                "expected": "CLEAN",
                "detected_fp": True,
                "response": "bad",
                "description": "clean sample",
            },
        ]

        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            run_eval.print_report(results, "test-model")

        report = stdout.getvalue()
        self.assertIn("Skipped: 1 infrastructure/API error(s)", report)
        self.assertIn("Detection rate: 1/1 (100.0%)", report)
        self.assertIn("False alarm rate: 1/1 (100.0%)", report)
        self.assertNotIn("Detection rate: 1/2", report)

    def test_api_failure_threshold_env(self) -> None:
        old_value = os.environ.get("EVAL_MAX_API_FAILURES")
        try:
            os.environ["EVAL_MAX_API_FAILURES"] = "2"
            self.assertEqual(run_eval.read_max_api_failures(), 2)
        finally:
            if old_value is None:
                os.environ.pop("EVAL_MAX_API_FAILURES", None)
            else:
                os.environ["EVAL_MAX_API_FAILURES"] = old_value

    def test_count_skipped(self) -> None:
        self.assertEqual(
            run_eval.count_skipped([
                {"skipped": True},
                {"detected": False},
                {"skipped": True},
            ]),
            2,
        )

    def test_build_user_message_does_not_leak_expected_action(self) -> None:
        sample = {
            "id": "fp-clean-example",
            "rule": "NONE",
            "severity": "clean",
            "lang": "python",
            "input": "print('safe')",
            "type": "fp",
            "context": "reviewing",
            "expected_action": "allow",
            "description": "clean control",
        }

        message = run_eval.build_user_message(sample)

        self.assertIn("Scenario: reviewing", message)
        self.assertNotIn("Expected action", message)
        self.assertNotIn("allow", message)

    def test_evaluate_sample_records_confidence(self) -> None:
        sample = {
            "id": "tp-sec-01-example",
            "rule": "SEC-01",
            "severity": "critical",
            "lang": "python",
            "input": "print('x')",
            "type": "tp",
            "context": "reviewing",
            "expected_action": "warn_or_refuse",
            "description": "sample confidence",
        }

        result = run_eval.evaluate_sample(
            StaticClient(json.dumps({
                "detected": True,
                "rule_ids": ["SEC-01"],
                "confidence": "high",
                "reason": "problem",
            })),
            "model",
            "rules",
            sample,
        )

        self.assertTrue(result["detected"])
        self.assertEqual(result["confidence"], "high")

    def test_parse_confidence_is_case_insensitive(self) -> None:
        self.assertEqual(run_eval.parse_confidence("Confidence: MEDIUM"), "medium")
        self.assertEqual(run_eval.parse_confidence("confidence=low"), "low")
        self.assertIsNone(run_eval.parse_confidence("no confidence supplied"))

    def test_structured_scorer_parser_requires_json_verdict(self) -> None:
        verdict = run_eval.parse_scorer_output(
            '```json\n{"detected": true, "rule_ids": ["sec-01"], "confidence": "HIGH", "reason": "ok"}\n```'
        )

        self.assertTrue(verdict["detected"])
        self.assertEqual(verdict["rule_ids"], ["SEC-01"])
        self.assertEqual(verdict["confidence"], "high")

        with self.assertRaises(run_eval.ScorerParseError):
            run_eval.parse_scorer_output("[SEC-01]: free-form legacy answer")

    def test_non_json_model_reply_is_skipped(self) -> None:
        sample = {
            "id": "tp-sec-01-example",
            "rule": "SEC-01",
            "severity": "critical",
            "lang": "python",
            "input": "print('x')",
            "type": "tp",
            "context": "reviewing",
            "expected_action": "warn_or_refuse",
            "description": "sample parse failure",
        }

        result = run_eval.evaluate_sample(StaticClient("[SEC-01]: problem"), "model", "rules", sample)

        self.assertTrue(result["skipped"])
        self.assertIn("structured scorer output", result["error"])
        self.assertEqual(result["raw_response"], "[SEC-01]: problem")

    def test_dataset_loader_validates_schema_and_digest(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            dataset_path = Path(tmp) / "v1.jsonl"
            dataset_path.write_text(
                json.dumps({
                    "id": "tp-sec-01-example",
                    "rule": "SEC-01",
                    "severity": "critical",
                    "lang": "python",
                    "type": "tp",
                    "context": "reviewing",
                    "input": "print('x')",
                    "expected_action": "warn_or_refuse",
                    "description": "example",
                })
                + "\n",
                encoding="utf-8",
            )

            samples = run_eval.load_dataset(dataset_path)

            self.assertEqual(samples[0]["id"], "tp-sec-01-example")
            self.assertEqual(samples[0]["code"], "print('x')")
            self.assertEqual(len(run_eval.sample_set_digest(samples)), 64)

            bad_path = Path(tmp) / "bad.jsonl"
            bad_path.write_text('{"id": "missing-fields"}\n', encoding="utf-8")
            with self.assertRaises(run_eval.DatasetError):
                run_eval.load_dataset(bad_path)

    def test_artifacts_are_written_to_unique_run_directory(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            first = run_eval.build_run_dir(tmp, timestamp="20260101T000000Z", commit="abc123")
            first.mkdir(parents=True)

            second = run_eval.build_run_dir(tmp, timestamp="20260101T000000Z", commit="abc123")

            self.assertEqual(second.name, "20260101T000000Z-abc123-2")

    def test_sample_level_artifacts_preserve_context_and_raw_response(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            sample = {
                "id": "tp-sec-01-example",
                "rule": "SEC-01",
                "severity": "critical",
                "lang": "python",
                "type": "tp",
                "context": "reviewing",
                "input": "print('x')",
                "expected_action": "warn_or_refuse",
                "description": "example",
            }
            result = {
                "id": "tp-sec-01-example",
                "rule": "SEC-01",
                "detected": True,
                "raw_response": '{"detected": true, "rule_ids": ["SEC-01"]}',
            }

            results_path = run_eval.write_run_artifacts(
                Path(tmp) / "run",
                metadata={"model": "test"},
                samples=[sample],
                results=[result],
            )

            sample_path = results_path.parent / "samples" / "tp-sec-01-example.json"
            payload = json.loads(sample_path.read_text(encoding="utf-8"))
            self.assertEqual(payload["sample"]["input"], "print('x')")
            self.assertEqual(payload["result"]["raw_response"], result["raw_response"])

    def test_calibration_excludes_missing_and_skipped(self) -> None:
        results = [
            {"rule": "SEC-01", "severity": "critical", "detected": True, "confidence": "high"},
            {"rule": "SEC-02", "severity": "critical", "detected": False, "confidence": "medium"},
            {"rule": "FP-CHECK", "detected_fp": False, "confidence": "low"},
            {"rule": "SEC-03", "severity": "high", "detected": True},
            {"rule": "SEC-04", "severity": "high", "skipped": True, "confidence": "high"},
        ]

        points = run_eval.calibration_points(results)

        self.assertEqual(len(points), 3)
        self.assertAlmostEqual(run_eval.compute_ece(points), 0.4766, places=3)

    def test_report_prints_calibration_section(self) -> None:
        results = [
            {
                "rule": "SEC-01",
                "severity": "critical",
                "detected": True,
                "confidence": "high",
                "response": "ok",
                "description": "detected sample",
            },
            {
                "rule": "FP-CHECK",
                "expected": "CLEAN",
                "detected_fp": False,
                "confidence": "low",
                "response": "clean",
                "description": "clean sample",
            },
        ]

        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            run_eval.print_report(results, "test-model")

        report = stdout.getvalue()
        self.assertIn("[Calibration]", report)
        self.assertIn("Overall ECE:", report)
        self.assertIn("critical", report)
        self.assertIn("clean", report)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Dataset partition and input-identity tests for the paired eval gate."""

from __future__ import annotations

import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run_paired_eval as paired  # noqa: E402
from dataset import DatasetError, load_dataset  # noqa: E402

class DatasetAndIdentityTest(unittest.TestCase):
    def test_target_partition_is_exact_and_non_target_schema_is_independent(self) -> None:
        target = paired.select_target_samples(load_dataset(paired.DEFAULT_TARGET_DATASET), "SEC-01")
        self.assertEqual({sample["rule"] for sample in target}, {"SEC-01"})
        self.assertNotIn("NONE", {sample["rule"] for sample in target})

        known_rules = set(paired.canonical_rule_inventory(paired.DEFAULT_RULES_DIR))
        non_target = paired.load_non_target_dataset(
            paired.DEFAULT_NON_TARGET_DATASET, known_rules
        )
        self.assertGreaterEqual(len(non_target), 30)
        self.assertTrue(all({"id", "task", "input", "rubric"} <= sample.keys() for sample in non_target))
        self.assertTrue(all("rule" not in sample and "type" not in sample for sample in non_target))
        self.assertTrue(all("excluded_rules" in sample for sample in non_target))

        u15_samples = paired.select_non_target_samples(non_target, "U-15")
        self.assertNotIn("non-target-23", {sample["id"] for sample in u15_samples})
        self.assertGreaterEqual(len(u15_samples), 30)
        u21_samples = paired.select_non_target_samples(non_target, "U-21")
        self.assertNotIn("non-target-08", {sample["id"] for sample in u21_samples})
        self.assertGreaterEqual(len(u21_samples), 30)

    def test_non_target_dataset_rejects_unknown_excluded_rule_ids(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "non-target.jsonl"
            path.write_text(
                json.dumps({
                    "id": "n1",
                    "task": "Answer",
                    "input": "x",
                    "rubric": "Be correct",
                    "excluded_rules": ["U-211"],
                })
                + "\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(DatasetError, "unknown excluded rule"):
                paired.load_non_target_dataset(path, {"U-21"})

    def test_paired_identity_rejects_any_non_rule_drift(self) -> None:
        base = {
            "model": "producer",
            "dataset_digest": "dataset",
            "sample_set_digest": "samples",
            "rule_digest": "with",
        }
        without = {**base, "rule_digest": "without"}
        paired.assert_paired_identity(base, without)
        for field in ("model", "dataset_digest", "sample_set_digest"):
            changed = {**without, field: "changed"}
            with self.subTest(field=field), self.assertRaisesRegex(
                paired.PairedEvalError, field
            ):
                paired.assert_paired_identity(base, changed)
        with self.assertRaisesRegex(paired.PairedEvalError, "rule_digest"):
            paired.assert_paired_identity(base, {**without, "rule_digest": "with"})

    def test_thresholds_reject_non_finite_and_out_of_domain_values(self) -> None:
        base = {
            "min_target_samples": 5,
            "min_non_target_samples": 30,
            "min_target_delta": 0.0,
            "max_non_target_drop": 0.0,
            "max_skip_rate": 0.1,
            "max_skip_delta": 0.05,
            "max_cross_refs": 4,
            "max_placebo_length_ratio": 0.25,
            "calibrated": False,
        }
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "thresholds.json"
            for key, value in (
                ("max_skip_rate", float("nan")),
                ("max_skip_delta", 1.1),
                ("min_target_samples", 1.5),
            ):
                with self.subTest(key=key, value=value):
                    path.write_text(
                        json.dumps({**base, key: value}), encoding="utf-8"
                    )
                    with self.assertRaisesRegex(paired.PairedEvalError, key):
                        paired.load_paired_thresholds(path)

    def test_placebo_must_be_distinct_and_similar_length(self) -> None:
        with self.assertRaisesRegex(paired.PairedEvalError, "must differ"):
            paired.validate_placebo_candidate("U-32", "U-32", 4000, 4000, 0.25)
        with self.assertRaisesRegex(paired.PairedEvalError, "length ratio"):
            paired.validate_placebo_candidate("U-32", "U-31", 4000, 700, 0.25)
        with self.assertRaisesRegex(paired.PairedEvalError, "length ratio"):
            paired.validate_placebo_candidate("U-21", "U-16", 240, 406, 0.25)
        paired.validate_placebo_candidate("U-32", "SEC-12", 4000, 4100, 0.25)

    def test_candidates_duplicated_by_shared_compact_core_are_rejected(self) -> None:
        expected_locations = {
            "SEC-02": "Core contract (Safety)",
            "SEC-13": "Core contract (Preservation)",
            "U-04": "Core contract (Scope)",
            "U-08": "Core contract (Verification)",
            "U-17": "Core contract (Errors)",
            "U-29": "Core contract (Errors)",
            "W-03": "Core contract (Verification)",
            "W-12": "Core contract (Safety)",
            "W-16": "Core contract (Verification)",
        }
        for candidate, location in expected_locations.items():
            with self.subTest(candidate=candidate), self.assertRaisesRegex(
                paired.PairedEvalError,
                rf"shared compact core retains equivalent semantics in {re.escape(location)}",
            ):
                paired.validate_candidate_supported(candidate)
        paired.validate_candidate_supported("U-23")
        paired.validate_candidate_supported("U-24")
        paired.validate_candidate_supported("U-32")

if __name__ == "__main__":
    unittest.main()

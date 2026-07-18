#!/usr/bin/env python3
"""Tests for the offline eval model baseline contract."""

from __future__ import annotations

import copy
import json
import tempfile
import unittest
from datetime import date, timedelta
from pathlib import Path

from model_baseline import (
    DEFAULT_BASELINE_PATH,
    ModelBaselineError,
    load_model_baseline,
)

VERIFIED_AT = date(2026, 7, 17)


class ModelBaselineTest(unittest.TestCase):
    def setUp(self) -> None:
        self.valid = json.loads(DEFAULT_BASELINE_PATH.read_text(encoding="utf-8"))

    def write_baseline(self, value: object) -> tuple[tempfile.TemporaryDirectory, Path]:
        temporary = tempfile.TemporaryDirectory()
        path = Path(temporary.name) / "baseline.json"
        path.write_text(json.dumps(value), encoding="utf-8")
        return temporary, path

    def assert_invalid(self, value: object, expected: str) -> None:
        temporary, path = self.write_baseline(value)
        self.addCleanup(temporary.cleanup)
        with self.assertRaisesRegex(ModelBaselineError, expected):
            load_model_baseline(path, as_of=VERIFIED_AT)

    def test_checked_in_manifest_has_exact_resolution_contract(self) -> None:
        baseline = load_model_baseline(DEFAULT_BASELINE_PATH, as_of=VERIFIED_AT)

        self.assertEqual(baseline.default_alias, "haiku")
        self.assertEqual(baseline.resolve("haiku"), "claude-haiku-4-5-20251001")
        self.assertEqual(baseline.resolve("sonnet"), "claude-sonnet-5")
        self.assertEqual(baseline.resolve("opus"), "claude-opus-4-8")
        self.assertEqual(baseline.resolve("claude-sonnet-4-6"), "claude-sonnet-4-6")
        self.assertEqual(baseline.age_days, 0)

    def test_freshness_boundary_is_utc_day_0_through_90_inclusive(self) -> None:
        for age in (0, 89, 90):
            with self.subTest(age=age):
                baseline = load_model_baseline(
                    DEFAULT_BASELINE_PATH,
                    as_of=VERIFIED_AT + timedelta(days=age),
                )
                self.assertEqual(baseline.age_days, age)

        with self.assertRaisesRegex(ModelBaselineError, "stale: age_days=91"):
            load_model_baseline(
                DEFAULT_BASELINE_PATH,
                as_of=VERIFIED_AT + timedelta(days=91),
            )

    def test_future_verified_date_fails(self) -> None:
        with self.assertRaisesRegex(ModelBaselineError, "must not be in the future"):
            load_model_baseline(
                DEFAULT_BASELINE_PATH,
                as_of=VERIFIED_AT - timedelta(days=1),
            )

    def test_root_keys_are_closed(self) -> None:
        missing = copy.deepcopy(self.valid)
        missing.pop("official_source")
        self.assert_invalid(missing, "missing=\\['official_source'\\]")

        extra = copy.deepcopy(self.valid)
        extra["evergreen"] = True
        self.assert_invalid(extra, "extra=\\['evergreen'\\]")

    def test_schema_and_freshness_are_exact_integers(self) -> None:
        for field, value, expected in (
            ("schema_version", True, "schema_version must be integer 1"),
            ("schema_version", 2, "schema_version must be integer 1"),
            ("freshness_days", True, "freshness_days must be integer 90"),
            ("freshness_days", 89, "freshness_days must be integer 90"),
        ):
            with self.subTest(field=field, value=value):
                invalid = copy.deepcopy(self.valid)
                invalid[field] = value
                self.assert_invalid(invalid, expected)

    def test_alias_map_is_closed_unique_and_nonempty(self) -> None:
        missing = copy.deepcopy(self.valid)
        missing["aliases"].pop("opus")
        self.assert_invalid(missing, "aliases keys mismatch")

        extra = copy.deepcopy(self.valid)
        extra["aliases"]["fable"] = "claude-fable-5"
        self.assert_invalid(extra, "aliases keys mismatch")

        empty = copy.deepcopy(self.valid)
        empty["aliases"]["opus"] = ""
        self.assert_invalid(empty, "aliases.opus must be a non-empty string")

        duplicate = copy.deepcopy(self.valid)
        duplicate["aliases"]["opus"] = duplicate["aliases"]["sonnet"]
        self.assert_invalid(duplicate, "alias targets must be unique")

    def test_default_source_and_date_are_strict(self) -> None:
        invalid_default = copy.deepcopy(self.valid)
        invalid_default["default_alias"] = "fable"
        self.assert_invalid(invalid_default, "default_alias must name an alias")

        invalid_source = copy.deepcopy(self.valid)
        invalid_source["official_source"] = "https://example.com/models"
        self.assert_invalid(invalid_source, "official_source must be")

        invalid_date = copy.deepcopy(self.valid)
        invalid_date["verified_at"] = "2026-7-17"
        self.assert_invalid(invalid_date, "ISO YYYY-MM-DD")

    def test_malformed_missing_and_empty_requested_model_fail_visibly(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        malformed = Path(temporary.name) / "malformed.json"
        malformed.write_text("{", encoding="utf-8")
        with self.assertRaisesRegex(ModelBaselineError, "invalid JSON"):
            load_model_baseline(malformed, as_of=VERIFIED_AT)

        with self.assertRaisesRegex(ModelBaselineError, "cannot read"):
            load_model_baseline(Path(temporary.name) / "missing.json", as_of=VERIFIED_AT)

        baseline = load_model_baseline(DEFAULT_BASELINE_PATH, as_of=VERIFIED_AT)
        with self.assertRaisesRegex(ModelBaselineError, "must not be empty"):
            baseline.resolve("")


if __name__ == "__main__":
    unittest.main()

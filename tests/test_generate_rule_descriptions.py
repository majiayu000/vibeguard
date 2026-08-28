#!/usr/bin/env python3
"""Regression tests for the generated runtime rule-description catalog."""

from __future__ import annotations

import importlib.util
import json
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GENERATOR_PATH = ROOT / "scripts" / "generate_rule_descriptions.py"
SPEC = importlib.util.spec_from_file_location("generate_rule_descriptions", GENERATOR_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load generator module: {GENERATOR_PATH}")
generate_rule_descriptions = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = generate_rule_descriptions
SPEC.loader.exec_module(generate_rule_descriptions)


class RuleDescriptionGenerationTests(unittest.TestCase):
    def test_catalog_covers_every_canonical_rule_deterministically(self) -> None:
        rules = generate_rule_descriptions.parse_rules()

        first = generate_rule_descriptions.render_rule_descriptions(rules)
        second = generate_rule_descriptions.render_rule_descriptions(rules)
        catalog = json.loads(first)

        self.assertEqual(first, second)
        self.assertEqual(catalog["schema_version"], 1)
        self.assertEqual(catalog["generated_from"], "rules/claude-rules/**")
        self.assertEqual(set(catalog["rules"]), {rule.id for rule in rules})
        self.assertEqual(
            catalog["rules"]["U-32"],
            {
                "name": "Rule overload threshold + absolute-language detection",
                "severity": "Strict",
                "description": (
                    "Keep the effective constraint set for a single agent task at 15 or fewer items."
                ),
            },
        )
        self.assertEqual(
            catalog["rules"]["W-03"]["description"],
            "Verify before claiming completion: produce fresh command output proving the claim.",
        )

    def test_checked_in_catalog_is_current(self) -> None:
        expected = generate_rule_descriptions.render_rule_descriptions(
            generate_rule_descriptions.parse_rules()
        )

        self.assertEqual(
            generate_rule_descriptions.RULE_DESCRIPTIONS_PATH.read_text(encoding="utf-8"),
            expected,
        )

    def test_generated_rule_docs_gate_checks_catalog_freshness(self) -> None:
        validator = (ROOT / "scripts" / "ci" / "validate-generated-rule-docs.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn("python3 scripts/generate_rule_descriptions.py --check", validator)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Candidate-rule removal and repository inventory tests for the paired eval gate."""

from __future__ import annotations

import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run_paired_eval as paired  # noqa: E402

class RemovalFixture(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.real = self.root / "real"
        self.real.mkdir()
        (self.real / "rules.md").write_bytes(
            b"# Rules\r\n\r\n"
            b"## U-01: candidate\r\n\r\ncandidate body\r\n\r\n"
            b"## U-02: neighbor\r\n\r\nneighbor body\r\n"
        )
        (self.real / "other.md").write_bytes(
            b"## W-01: other\n\nSee U-01 for related guidance.\n"
        )
        self.core = self.root / "core.md"
        self.core.write_bytes(
            b"| ID | Rule |\n"
            b"| --- | --- |\n"
            b"| U-01 | candidate core |\n"
            b"| W-01 | other core |\nCore note: U-01 still applies.\n"
        )
        self.section = paired.extract_candidate_section(
            (self.real / "rules.md").read_bytes(), "U-01"
        )

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def copy_pair(self) -> tuple[Path, Path]:
        mutated = self.root / f"mutated-{len(list(self.root.glob('mutated-*')))}"
        shutil.copytree(self.real, mutated)
        core = self.root / f"core-{mutated.name}.md"
        shutil.copy2(self.core, core)
        return mutated, core

    def audit(self, mutated: Path, core: Path, removed: bytes | None = None) -> set[str]:
        evidence = paired.audit_removal(
            self.real,
            mutated,
            self.core,
            core,
            "U-01",
            expected_rule_file=Path("rules.md"),
            expected_removed_section=removed or self.section,
        )
        return set(evidence["failed_assertions"])

    def test_valid_dual_source_removal_preserves_bytes(self) -> None:
        mutated, core = self.copy_pair()
        source = (mutated / "rules.md").read_bytes()
        stripped, removed = paired.strip_candidate_section(source, "U-01")
        (mutated / "rules.md").write_bytes(stripped)
        core.write_bytes(paired.strip_core_row(core.read_bytes(), "U-01")[0])

        evidence = paired.audit_removal(
            self.real,
            mutated,
            self.core,
            core,
            "U-01",
            expected_rule_file=Path("rules.md"),
            expected_removed_section=removed,
        )

        self.assertEqual(evidence["failed_assertions"], [])
        self.assertEqual(evidence["assertions"], {
            "file_set": "pass",
            "presence": "pass",
            "definition_site": "pass",
            "file_diff": "pass",
            "definition_count": "pass",
        })
        self.assertEqual(evidence["cross_references"], ["other.md:3", "core.md:5"])

    def test_mutations_are_caught_by_independent_named_assertions(self) -> None:
        cases: list[tuple[str, str, callable]] = []

        def no_op(tree: Path, core: Path) -> bytes:
            return self.section

        cases.append(("no-op", "definition_site", no_op))

        def greedy_next(tree: Path, core: Path) -> bytes:
            source = (tree / "rules.md").read_bytes()
            start = source.index(b"## U-01:")
            removed = source[start:]
            (tree / "rules.md").write_bytes(source[:start])
            core.write_bytes(paired.strip_core_row(core.read_bytes(), "U-01")[0])
            return removed

        cases.append(("greedy-to-eof", "definition_count", greedy_next))

        def whole_file(tree: Path, core: Path) -> bytes:
            (tree / "rules.md").write_bytes(b"")
            core.write_bytes(paired.strip_core_row(core.read_bytes(), "U-01")[0])
            return self.section

        cases.append(("whole-file", "file_diff", whole_file))

        def only_core(tree: Path, core: Path) -> bytes:
            core.write_bytes(paired.strip_core_row(core.read_bytes(), "U-01")[0])
            return self.section

        cases.append(("only-core", "definition_site", only_core))

        def only_section(tree: Path, core: Path) -> bytes:
            stripped, removed = paired.strip_candidate_section(
                (tree / "rules.md").read_bytes(), "U-01"
            )
            (tree / "rules.md").write_bytes(stripped)
            return removed

        cases.append(("only-section", "definition_site", only_section))

        def title_only(tree: Path, core: Path) -> bytes:
            source = (tree / "rules.md").read_bytes()
            (tree / "rules.md").write_bytes(source.replace(b"## U-01: candidate\r\n", b"", 1))
            core.write_bytes(paired.strip_core_row(core.read_bytes(), "U-01")[0])
            return self.section

        cases.append(("title-only", "file_diff", title_only))

        def body_only(tree: Path, core: Path) -> bytes:
            source = (tree / "rules.md").read_bytes()
            (tree / "rules.md").write_bytes(source.replace(b"candidate body\r\n\r\n", b"", 1))
            core.write_bytes(paired.strip_core_row(core.read_bytes(), "U-01")[0])
            return self.section

        cases.append(("body-only", "definition_site", body_only))

        for name, expected, mutate in cases:
            with self.subTest(name=name):
                tree, core = self.copy_pair()
                removed = mutate(tree, core)
                self.assertIn(expected, self.audit(tree, core, removed))

    def test_file_set_and_byte_drift_mutations_are_rejected(self) -> None:
        missing, missing_core = self.copy_pair()
        (missing / "other.md").unlink()
        self.assertIn("file_set", self.audit(missing, missing_core))

        extra, extra_core = self.copy_pair()
        (extra / "extra.md").write_text("extra", encoding="utf-8")
        self.assertIn("file_set", self.audit(extra, extra_core))

        drift, drift_core = self.copy_pair()
        stripped, removed = paired.strip_candidate_section(
            (drift / "rules.md").read_bytes(), "U-01"
        )
        (drift / "rules.md").write_bytes(stripped)
        drift_core.write_bytes(paired.strip_core_row(drift_core.read_bytes(), "U-01")[0])
        (drift / "other.md").write_bytes(
            (drift / "other.md").read_bytes().replace(b"\n", b"\r\n")
        )
        self.assertIn("file_diff", self.audit(drift, drift_core, removed))


class RepositoryRemovalTest(unittest.TestCase):
    def test_canonical_inventory_and_all_rule_smoke(self) -> None:
        inventory = paired.canonical_rule_inventory(paired.DEFAULT_RULES_DIR)
        self.assertEqual(len(inventory), 127)
        self.assertEqual(len(set(inventory)), 127)
        self.assertTrue(
            {"TASTE-ANSI", "TASTE-ASYNC-UNWRAP", "TASTE-PANIC-MSG"}.issubset(inventory)
        )

        with tempfile.TemporaryDirectory() as tmp:
            empty_shells = set()
            cross_ref_rules = set()
            for rule_id in inventory:
                evidence = paired.prepare_without_rules(
                    paired.DEFAULT_RULES_DIR,
                    paired.DEFAULT_CORE_RULES_FILE,
                    rule_id,
                    Path(tmp) / rule_id,
                )
                self.assertEqual(evidence["failed_assertions"], [], rule_id)
                if evidence["empty_shells"]:
                    empty_shells.add(rule_id)
                if evidence["cross_references"]:
                    cross_ref_rules.add(rule_id)

        self.assertEqual(len(empty_shells), 10)
        self.assertEqual(len(cross_ref_rules), 29)

    def test_u32_cross_reference_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            evidence = paired.prepare_without_rules(
                paired.DEFAULT_RULES_DIR,
                paired.DEFAULT_CORE_RULES_FILE,
                "U-32",
                Path(tmp) / "candidate",
            )

        self.assertEqual(len(evidence["cross_references"]), 12)
        self.assertTrue(paired.cross_reference_limit_exceeded(evidence, 4))
        fixture = {"cross_references": [f"fixture.md:{line}" for line in range(1, 5)]}
        self.assertFalse(paired.cross_reference_limit_exceeded(fixture, 4))
        fixture["cross_references"].append("fixture.md:5")
        self.assertTrue(paired.cross_reference_limit_exceeded(fixture, 4))

    def test_w11_literal_markdown_headings_are_removed_with_the_rule(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            evidence = paired.prepare_without_rules(
                paired.DEFAULT_RULES_DIR,
                paired.DEFAULT_CORE_RULES_FILE,
                "W-11",
                Path(tmp) / "candidate",
            )
            without = (
                evidence["rules_dir"] / "common" / "fact-inference-separation.md"
            ).read_text(encoding="utf-8")

        self.assertNotIn("## Facts", without)
        self.assertNotIn("## Inferences", without)
        self.assertEqual(evidence["failed_assertions"], [])

if __name__ == "__main__":
    unittest.main()

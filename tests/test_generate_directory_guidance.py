#!/usr/bin/env python3
"""Regression tests for scoped directory-guidance generation."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GENERATOR_PATH = ROOT / "scripts" / "generate_directory_guidance.py"
SPEC = importlib.util.spec_from_file_location("generate_directory_guidance", GENERATOR_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load generator: {GENERATOR_PATH}")
generator = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = generator
SPEC.loader.exec_module(generator)


class DirectoryGuidanceTests(unittest.TestCase):
    def test_parse_sections_adds_generated_header(self) -> None:
        source = """\
<!-- directory-guidance:guards/CLAUDE.md:start -->
# Guards
<!-- directory-guidance:guards/CLAUDE.md:end -->
"""
        original_outputs = generator.EXPECTED_OUTPUTS
        try:
            generator.EXPECTED_OUTPUTS = {"guards/CLAUDE.md"}
            sections = generator.parse_sections(source)
        finally:
            generator.EXPECTED_OUTPUTS = original_outputs
        self.assertEqual(
            sections["guards/CLAUDE.md"],
            generator.GENERATED_HEADER + "# Guards\n",
        )

    def test_symlink_output_is_rejected_for_check_and_write(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "guards").mkdir()
            secret = root / "secret.txt"
            secret.write_text("secret\n", encoding="utf-8")
            (root / "guards" / "CLAUDE.md").symlink_to(secret)
            sections = {"guards/CLAUDE.md": generator.GENERATED_HEADER + "# Guards\n"}

            with self.assertRaisesRegex(ValueError, "regular file"):
                generator.check_outputs(sections, root)
            with self.assertRaisesRegex(ValueError, "regular file"):
                generator.write_outputs(sections, root)
            self.assertEqual(secret.read_text(encoding="utf-8"), "secret\n")

    def test_atomic_write_replaces_regular_file_and_preserves_mode(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "guards").mkdir()
            output = root / "guards" / "CLAUDE.md"
            output.write_text("old\n", encoding="utf-8")
            output.chmod(0o640)
            expected = generator.GENERATED_HEADER + "# Guards\n"

            generator.write_outputs({"guards/CLAUDE.md": expected}, root)

            self.assertEqual(output.read_text(encoding="utf-8"), expected)
            self.assertEqual(output.stat().st_mode & 0o777, 0o640)

    def test_open_directory_descriptor_contains_parent_swap(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            guards = root / "guards"
            guards.mkdir()
            (guards / "CLAUDE.md").write_text("old\n", encoding="utf-8")
            outside = root / "outside"
            outside.mkdir()
            original = root / "guards-original"
            expected = generator.GENERATED_HEADER + "# Guards\n"

            with generator.open_parent_directory(
                root, "guards/CLAUDE.md"
            ) as (parent_descriptor, name):
                guards.rename(original)
                guards.symlink_to(outside, target_is_directory=True)
                generator.atomic_write_at(
                    parent_descriptor,
                    name,
                    "guards/CLAUDE.md",
                    expected,
                )

            self.assertEqual(
                (original / "CLAUDE.md").read_text(encoding="utf-8"),
                expected,
            )
            self.assertFalse((outside / "CLAUDE.md").exists())

    def test_retired_scoped_output_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            retired = root / "guards" / "rust" / "CLAUDE.md"
            retired.parent.mkdir(parents=True)
            retired.write_text("old guidance\n", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "retired scoped guidance"):
                generator.validate_output_inventory(
                    root,
                    {"guards/CLAUDE.md"},
                    {"guards/rust/CLAUDE.md"},
                )

    def test_orphaned_generated_output_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            orphan = root / "old" / "CLAUDE.md"
            orphan.parent.mkdir()
            orphan.write_text(generator.GENERATED_HEADER + "# Old\n", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "orphaned generated"):
                generator.validate_output_inventory(root, set(), set())


if __name__ == "__main__":
    unittest.main()

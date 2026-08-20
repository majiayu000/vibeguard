#!/usr/bin/env python3
"""Regression tests for scoped directory-guidance generation."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from unittest import mock
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

    def test_unlisted_handwritten_guidance_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            unlisted = root / "guards" / "nested" / "CLAUDE.md"
            unlisted.parent.mkdir(parents=True)
            unlisted.write_text("# Handwritten\n", encoding="utf-8")

            with self.assertRaisesRegex(
                ValueError,
                "scoped guidance outside canonical inventory",
            ):
                generator.validate_output_inventory(
                    root,
                    {"guards/CLAUDE.md"},
                    set(),
                )

    def test_symlinked_scoped_guidance_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            expected = root / "guards" / "CLAUDE.md"
            expected.parent.mkdir()
            expected.write_text(generator.GENERATED_HEADER + "# Guards\n", encoding="utf-8")
            orphan = root / "guards" / "nested" / "CLAUDE.md"
            orphan.parent.mkdir()
            orphan.symlink_to(expected)

            with self.assertRaisesRegex(ValueError, "symlinked scoped guidance"):
                generator.validate_output_inventory(
                    root,
                    {"guards/CLAUDE.md"},
                    set(),
                )

    def test_symlinked_directory_that_hides_guidance_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            with tempfile.TemporaryDirectory() as outside_directory:
                root = Path(temporary_directory)
                outside = Path(outside_directory)
                (outside / "CLAUDE.md").write_text("# Hidden\n", encoding="utf-8")
                (root / "linked").symlink_to(outside, target_is_directory=True)

                with self.assertRaisesRegex(ValueError, "symlinked directory"):
                    generator.validate_output_inventory(root, set(), set())

    def test_directory_swap_to_symlink_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            with tempfile.TemporaryDirectory() as outside_directory:
                root = Path(temporary_directory)
                scanned = root / "scanned"
                scanned.mkdir()
                outside = Path(outside_directory)
                (outside / "CLAUDE.md").write_text("# Hidden\n", encoding="utf-8")
                original_open = generator.os.open
                swapped = False

                def swap_before_open(
                    path: str | bytes | int,
                    flags: int,
                    mode: int = 0o777,
                    *,
                    dir_fd: int | None = None,
                ) -> int:
                    nonlocal swapped
                    if path == "scanned" and dir_fd is not None and not swapped:
                        scanned.rename(root / "scanned-original")
                        scanned.symlink_to(outside, target_is_directory=True)
                        swapped = True
                    return original_open(path, flags, mode, dir_fd=dir_fd)

                with mock.patch.object(generator.os, "open", side_effect=swap_before_open):
                    with self.assertRaisesRegex(
                        ValueError,
                        "cannot inspect directory-guidance inventory",
                    ):
                        generator.validate_output_inventory(root, set(), set())

    def test_isolated_worktree_roots_are_excluded_from_inventory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            for worktree_root in (".claude/worktrees", ".vibeguard/worktrees"):
                nested_guidance = root / worktree_root / "review" / "guards" / "CLAUDE.md"
                nested_guidance.parent.mkdir(parents=True)
                nested_guidance.write_text(
                    generator.GENERATED_HEADER + "# Nested checkout\n",
                    encoding="utf-8",
                )

            generator.validate_output_inventory(root, set(), set())


if __name__ == "__main__":
    unittest.main()

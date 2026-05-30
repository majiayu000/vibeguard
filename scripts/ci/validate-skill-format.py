#!/usr/bin/env python3
"""Validate VibeGuard-owned SKILL.md structure."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


REQUIRED_SECTIONS = ("When to Activate", "Red Flags", "Checklist")
MIN_RED_FLAGS = 3
MIN_CHECKLIST_ITEMS = 3
FRONTMATTER_FIELD_PATTERN = re.compile(r"^[A-Za-z][A-Za-z0-9_-]*:\s*.*$")
FRONTMATTER_BLOCK_SCALAR_PATTERN = re.compile(r"^[A-Za-z][A-Za-z0-9_-]*:\s*[|>][0-9]*[+-]?\s*(?:#.*)?$")


class SkillFormatError(Exception):
    """Raised for a single SKILL.md format problem."""


def default_skill_paths(repo_dir: Path) -> list[Path]:
    paths: list[Path] = []
    for root in (repo_dir / "skills", repo_dir / "workflows"):
        if root.is_dir():
            paths.extend(sorted(root.glob("*/SKILL.md")))
    return paths


def section_body(text: str, heading: str) -> str | None:
    pattern = re.compile(
        rf"(?ms)^##\s+{re.escape(heading)}\s*$\n(?P<body>.*?)(?=^##\s+|\Z)",
    )
    match = pattern.search(text)
    if not match:
        return None
    return match.group("body")


def count_plain_bullets(body: str) -> int:
    return sum(1 for line in body.splitlines() if re.match(r"^\s*-\s+\S", line))


def count_checklist_items(body: str) -> int:
    return sum(1 for line in body.splitlines() if re.match(r"^\s*-\s+\[[ xX]\]\s+\S", line))


def validate_frontmatter(path: Path, text: str) -> list[str]:
    errors: list[str] = []
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        errors.append("missing YAML frontmatter opening")
        return errors

    closing_index = next((index for index, line in enumerate(lines[1:], start=1) if line.strip() == "---"), None)
    if closing_index is None:
        errors.append("missing YAML frontmatter closing")
        return errors

    frontmatter_lines = lines[1:closing_index]
    in_block_scalar = False
    for line_number, line in enumerate(frontmatter_lines, start=2):
        if not line.strip():
            continue
        if line.startswith((" ", "\t")):
            if in_block_scalar:
                continue
            errors.append(f"invalid indented frontmatter line before closing delimiter: line {line_number}")
            return errors
        in_block_scalar = False
        if not FRONTMATTER_FIELD_PATTERN.match(line):
            errors.append(f"invalid frontmatter line before closing delimiter: line {line_number}")
            return errors
        if FRONTMATTER_BLOCK_SCALAR_PATTERN.match(line):
            in_block_scalar = True

    frontmatter = "\n".join(frontmatter_lines)
    for field in ("name", "description"):
        if not re.search(rf"(?m)^{field}:\s*\S", frontmatter):
            errors.append(f"missing frontmatter field: {field}")
    return errors


def validate_skill(path: Path) -> list[str]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise SkillFormatError(f"{path}: cannot read file: {exc}") from exc

    errors = validate_frontmatter(path, text)
    for heading in REQUIRED_SECTIONS:
        body = section_body(text, heading)
        if body is None:
            errors.append(f"missing ## {heading} section")
            continue
        if heading == "When to Activate" and count_plain_bullets(body) < 1:
            errors.append("## When to Activate must contain at least one bullet")
        elif heading == "Red Flags" and count_plain_bullets(body) < MIN_RED_FLAGS:
            errors.append(f"## Red Flags must contain at least {MIN_RED_FLAGS} bullets")
        elif heading == "Checklist" and count_checklist_items(body) < MIN_CHECKLIST_ITEMS:
            errors.append(f"## Checklist must contain at least {MIN_CHECKLIST_ITEMS} checkbox items")
    return errors


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Validate VibeGuard skill and workflow SKILL.md files.")
    parser.add_argument(
        "paths",
        nargs="*",
        help="Specific SKILL.md files to validate. Defaults to skills/*/SKILL.md and workflows/*/SKILL.md.",
    )
    parser.add_argument(
        "--repo-dir",
        default=".",
        help="Repository root used when no paths are provided.",
    )
    return parser


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    repo_dir = Path(args.repo_dir).resolve()
    paths = [Path(path).resolve() for path in args.paths] if args.paths else default_skill_paths(repo_dir)
    if not paths:
        print("No SKILL.md files found.", file=sys.stderr)
        return 2

    failure_count = 0
    for path in paths:
        errors = validate_skill(path)
        if errors:
            failure_count += len(errors)
            for error in errors:
                print(f"FAIL: {path}: {error}")
        else:
            print(f"OK: {path}")

    if failure_count:
        print(f"FAILED: {failure_count} skill format error(s).")
        return 1
    print(f"All {len(paths)} skill files passed format validation.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

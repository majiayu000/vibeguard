#!/usr/bin/env python3
"""Validate VibeGuard-owned SKILL.md and skill template structure."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts" / "lib"))
from skill_format import default_skill_paths, skill_format_errors  # noqa: E402


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Validate VibeGuard skill, workflow, and skill template files.")
    parser.add_argument(
        "paths",
        nargs="*",
        help=(
            "Specific SKILL.md files to validate. Defaults to skills/*/SKILL.md, "
            "workflows/*/SKILL.md, .claude/skills/*/SKILL.md, and templates/skill-template.md."
        ),
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
        errors = skill_format_errors(path)
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

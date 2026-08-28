#!/usr/bin/env python3
"""Generate the runtime rule-description catalog from canonical rules."""

from __future__ import annotations

import argparse
import difflib
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from generate_rule_docs import Rule, parse_rules, sort_rules  # noqa: E402


RULE_DESCRIPTIONS_PATH = ROOT / "rules" / "rule-descriptions.json"


def render_rule_descriptions(rules: list[Rule]) -> str:
    descriptions: dict[str, dict[str, str]] = {}
    for rule in sort_rules(rules):
        if rule.id in descriptions:
            raise ValueError(f"duplicate canonical rule id for description catalog: {rule.id}")
        descriptions[rule.id] = {
            "name": rule.name,
            "severity": rule.severity,
            "description": rule.compact_guidance or rule.summary,
        }
    return (
        json.dumps(
            {
                "schema_version": 1,
                "generated_from": "rules/claude-rules/**",
                "rules": descriptions,
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n"
    )


def check_catalog(expected: str) -> int:
    actual = RULE_DESCRIPTIONS_PATH.read_text(encoding="utf-8")
    if actual == expected:
        return 0
    print(
        f"Generated file drift detected: {RULE_DESCRIPTIONS_PATH.relative_to(ROOT)}",
        file=sys.stderr,
    )
    for line in difflib.unified_diff(
        actual.splitlines(),
        expected.splitlines(),
        fromfile=str(RULE_DESCRIPTIONS_PATH.relative_to(ROOT)),
        tofile=f"{RULE_DESCRIPTIONS_PATH.relative_to(ROOT)} (generated)",
        lineterm="",
    ):
        print(line, file=sys.stderr)
    return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if the catalog is out of date")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        expected = render_rule_descriptions(parse_rules())
        if args.check:
            return check_catalog(expected)
        RULE_DESCRIPTIONS_PATH.write_text(expected, encoding="utf-8")
        print(f"Updated {RULE_DESCRIPTIONS_PATH.relative_to(ROOT)}")
        return 0
    except (OSError, UnicodeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Strict, offline contract for VibeGuard eval model aliases."""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from datetime import date, datetime, timezone
from pathlib import Path
from types import MappingProxyType
from typing import Mapping

DEFAULT_BASELINE_PATH = Path(__file__).with_name("model_baseline.json")
EXPECTED_ALIASES = frozenset({"haiku", "sonnet", "opus"})
EXPECTED_SCHEMA_VERSION = 1
EXPECTED_FRESHNESS_DAYS = 90
OFFICIAL_SOURCE = "https://platform.claude.com/docs/en/about-claude/models/overview"


class ModelBaselineError(ValueError):
    """Raised when the checked-in model baseline violates its contract."""


@dataclass(frozen=True)
class ModelBaseline:
    aliases: Mapping[str, str]
    default_alias: str
    official_source: str
    verified_at: date
    freshness_days: int
    as_of: date

    @property
    def age_days(self) -> int:
        return (self.as_of - self.verified_at).days

    def resolve(self, requested: str) -> str:
        if not requested:
            raise ModelBaselineError("requested model must not be empty")
        return self.aliases.get(requested, requested)

    def alias_table(self) -> str:
        return ", ".join(
            f"{alias} -> {self.aliases[alias]}" for alias in sorted(self.aliases)
        )


def _require_exact_keys(value: object, expected: set[str], location: str) -> dict:
    if not isinstance(value, dict):
        raise ModelBaselineError(f"{location} must be an object")
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise ModelBaselineError(
            f"{location} keys mismatch: missing={missing}, extra={extra}"
        )
    return value


def _require_string(value: object, location: str) -> str:
    if not isinstance(value, str) or not value:
        raise ModelBaselineError(f"{location} must be a non-empty string")
    return value


def _parse_verified_at(value: object) -> date:
    text = _require_string(value, "verified_at")
    try:
        parsed = date.fromisoformat(text)
    except ValueError as error:
        raise ModelBaselineError("verified_at must be an ISO YYYY-MM-DD date") from error
    if parsed.isoformat() != text:
        raise ModelBaselineError("verified_at must use canonical YYYY-MM-DD form")
    return parsed


def _utc_today() -> date:
    return datetime.now(timezone.utc).date()


def load_model_baseline(
    path: Path = DEFAULT_BASELINE_PATH,
    *,
    as_of: date | None = None,
) -> ModelBaseline:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise ModelBaselineError(f"cannot read model baseline {path}: {error}") from error
    except json.JSONDecodeError as error:
        raise ModelBaselineError(f"model baseline is invalid JSON: {error.msg}") from error

    root = _require_exact_keys(
        raw,
        {
            "schema_version",
            "aliases",
            "default_alias",
            "official_source",
            "verified_at",
            "freshness_days",
        },
        "model baseline",
    )
    if type(root["schema_version"]) is not int or root["schema_version"] != EXPECTED_SCHEMA_VERSION:
        raise ModelBaselineError("schema_version must be integer 1")

    aliases_raw = _require_exact_keys(root["aliases"], set(EXPECTED_ALIASES), "aliases")
    aliases = {
        alias: _require_string(aliases_raw[alias], f"aliases.{alias}")
        for alias in sorted(EXPECTED_ALIASES)
    }
    if len(set(aliases.values())) != len(aliases):
        raise ModelBaselineError("alias targets must be unique")

    default_alias = _require_string(root["default_alias"], "default_alias")
    if default_alias not in aliases:
        raise ModelBaselineError("default_alias must name an alias")

    official_source = _require_string(root["official_source"], "official_source")
    if official_source != OFFICIAL_SOURCE:
        raise ModelBaselineError(f"official_source must be {OFFICIAL_SOURCE}")

    freshness_days = root["freshness_days"]
    if type(freshness_days) is not int or freshness_days != EXPECTED_FRESHNESS_DAYS:
        raise ModelBaselineError("freshness_days must be integer 90")

    verified_at = _parse_verified_at(root["verified_at"])
    current_date = as_of or _utc_today()
    age_days = (current_date - verified_at).days
    if age_days < 0:
        raise ModelBaselineError("verified_at must not be in the future relative to UTC")
    if age_days > freshness_days:
        raise ModelBaselineError(
            f"model baseline is stale: age_days={age_days}, limit={freshness_days}"
        )

    return ModelBaseline(
        aliases=MappingProxyType(aliases),
        default_alias=default_alias,
        official_source=official_source,
        verified_at=verified_at,
        freshness_days=freshness_days,
        as_of=current_date,
    )


def _parse_as_of(value: str) -> date:
    try:
        parsed = date.fromisoformat(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("expected YYYY-MM-DD") from error
    if parsed.isoformat() != value:
        raise argparse.ArgumentTypeError("expected canonical YYYY-MM-DD")
    return parsed


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate the offline eval model baseline")
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE_PATH)
    parser.add_argument("--as-of", type=_parse_as_of, help="inject UTC date for deterministic checks")
    args = parser.parse_args()
    try:
        baseline = load_model_baseline(args.baseline, as_of=args.as_of)
    except ModelBaselineError as error:
        print(f"Invalid eval model baseline: {error}", file=sys.stderr)
        return 2
    print(
        "OK: eval model baseline valid "
        f"(verified_at={baseline.verified_at.isoformat()}, "
        f"age_days={baseline.age_days}, freshness_days={baseline.freshness_days})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

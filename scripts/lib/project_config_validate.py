#!/usr/bin/env python3
"""Validate a project-level .vibeguard.json without third-party deps."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


def _label(path: list[str]) -> str:
    return "." + ".".join(path) if path else "$"


def _load_json(path: Path) -> Any:
    try:
        with path.open(encoding="utf-8") as f:
            return json.load(f)
    except UnicodeDecodeError as exc:
        raise ValueError(f"{path}: invalid UTF-8 ({exc})") from exc
    except json.JSONDecodeError as exc:
        raise ValueError(f"{path}: invalid JSON at line {exc.lineno}, column {exc.colno}: {exc.msg}") from exc
    except OSError as exc:
        raise ValueError(f"{path}: cannot read file ({exc})") from exc


def _enum(schema: dict[str, Any], key: str) -> set[str]:
    return set(schema["properties"][key]["items"].get("enum", []))


def _string_enum(schema: dict[str, Any], key: str) -> set[str]:
    return set(schema["properties"][key].get("enum", []))


def _validate_string_enum(
    value: Any,
    allowed: set[str],
    path: list[str],
    errors: list[str],
) -> None:
    if not isinstance(value, str):
        errors.append(f"{_label(path)}: expected string")
        return
    if value not in allowed:
        errors.append(f"{_label(path)}: unsupported value {value!r}; expected one of {sorted(allowed)}")


def _validate_string_array(
    value: Any,
    path: list[str],
    errors: list[str],
    *,
    allowed: set[str] | None = None,
    pattern: re.Pattern[str] | None = None,
) -> None:
    if not isinstance(value, list):
        errors.append(f"{_label(path)}: expected array")
        return

    for index, item in enumerate(value):
        item_path = path + [str(index)]
        if not isinstance(item, str):
            errors.append(f"{_label(item_path)}: expected string")
            continue
        if allowed is not None and item not in allowed:
            errors.append(f"{_label(item_path)}: unsupported value {item!r}; expected one of {sorted(allowed)}")
        if pattern is not None and not pattern.match(item):
            errors.append(f"{_label(item_path)}: does not match {pattern.pattern}")


def _validate_gc(value: Any, schema: dict[str, Any], errors: list[str]) -> None:
    path = ["gc"]
    if not isinstance(value, dict):
        errors.append(f"{_label(path)}: expected object")
        return

    gc_schema = schema["properties"]["gc"]
    props = gc_schema.get("properties", {})
    allowed = set(props)
    for key in sorted(set(value) - allowed):
        errors.append(f"{_label(path + [key])}: unknown property")

    for key, item in value.items():
        if key not in props:
            continue
        minimum = props[key].get("minimum", 1)
        item_path = path + [key]
        if isinstance(item, bool) or not isinstance(item, int):
            errors.append(f"{_label(item_path)}: expected integer >= {minimum}")
        elif item < minimum:
            errors.append(f"{_label(item_path)}: expected integer >= {minimum}")


def validate(config: Any, schema: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if not isinstance(config, dict):
        return ["$: expected object"]

    props = schema.get("properties", {})
    allowed_top = set(props)
    for key in sorted(set(config) - allowed_top):
        errors.append(f"{_label([key])}: unknown property")

    if "profile" in config:
        _validate_string_enum(config["profile"], _string_enum(schema, "profile"), ["profile"], errors)
    if "enforcement" in config:
        _validate_string_enum(config["enforcement"], _string_enum(schema, "enforcement"), ["enforcement"], errors)
    if "languages" in config:
        _validate_string_array(config["languages"], ["languages"], errors, allowed=_enum(schema, "languages"))
    if "disabled_hooks" in config:
        _validate_string_array(
            config["disabled_hooks"],
            ["disabled_hooks"],
            errors,
            allowed=_enum(schema, "disabled_hooks"),
        )
    if "disabled_guards" in config:
        _validate_string_array(
            config["disabled_guards"],
            ["disabled_guards"],
            errors,
            allowed=_enum(schema, "disabled_guards"),
        )
    if "disabled_rules" in config:
        pattern = re.compile(props["disabled_rules"]["items"]["pattern"])
        _validate_string_array(config["disabled_rules"], ["disabled_rules"], errors, pattern=pattern)
    if "gc" in config:
        _validate_gc(config["gc"], schema, errors)

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate .vibeguard.json against the project schema")
    parser.add_argument("config", type=Path)
    parser.add_argument("schema", type=Path)
    parser.add_argument("--quiet", action="store_true", help="Suppress success output")
    args = parser.parse_args()

    try:
        config = _load_json(args.config)
        schema = _load_json(args.schema)
    except ValueError as exc:
        print(f"VibeGuard project config invalid: {exc}", file=sys.stderr)
        return 1

    errors = validate(config, schema)
    if errors:
        print(f"VibeGuard project config invalid: {args.config}", file=sys.stderr)
        for error in errors:
            print(f"  {error}", file=sys.stderr)
        return 1

    if not args.quiet:
        print(f"OK: {args.config}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Validate executable workflow contracts against their Markdown consumers."""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SCHEMA_DIR = ROOT / "schemas"
DEFAULT_REGISTRY = DEFAULT_SCHEMA_DIR / "workflow-contract-consumers.json"
JSON_BLOCK_RE = re.compile(r"```json\s*(?P<body>.*?)\s*```", re.DOTALL)


@dataclass(frozen=True)
class ContractError:
    category: str
    message: str

    def format(self) -> str:
        return f"{self.category}: {self.message}"


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"{path}: invalid JSON: {exc.msg}") from exc


def _type_name(value: Any) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, str):
        return "string"
    if isinstance(value, int) and not isinstance(value, bool):
        return "integer"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    return type(value).__name__


def _type_matches(value: Any, expected: str) -> bool:
    if expected == "null":
        return value is None
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "string":
        return isinstance(value, str)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "array":
        return isinstance(value, list)
    if expected == "object":
        return isinstance(value, dict)
    return False


def validate_instance(instance: Any, schema: dict[str, Any], path: str = "$") -> list[str]:
    errors: list[str] = []

    expected_type = schema.get("type")
    if expected_type is not None:
        allowed_types = expected_type if isinstance(expected_type, list) else [expected_type]
        if not any(_type_matches(instance, item) for item in allowed_types):
            errors.append(f"{path}: expected {allowed_types}, got {_type_name(instance)}")
            return errors

    if "const" in schema and instance != schema["const"]:
        errors.append(f"{path}: expected const {schema['const']!r}, got {instance!r}")

    if "enum" in schema and instance not in schema["enum"]:
        errors.append(f"{path}: expected one of {schema['enum']}, got {instance!r}")

    if isinstance(instance, str):
        min_length = schema.get("minLength")
        if isinstance(min_length, int) and len(instance) < min_length:
            errors.append(f"{path}: string shorter than minLength {min_length}")
        pattern = schema.get("pattern")
        if isinstance(pattern, str) and not re.search(pattern, instance):
            errors.append(f"{path}: string does not match pattern {pattern!r}")

    if isinstance(instance, list):
        min_items = schema.get("minItems")
        if isinstance(min_items, int) and len(instance) < min_items:
            errors.append(f"{path}: array shorter than minItems {min_items}")
        if schema.get("uniqueItems") is True:
            encoded = [json.dumps(item, sort_keys=True) for item in instance]
            if len(encoded) != len(set(encoded)):
                errors.append(f"{path}: array items must be unique")
        item_schema = schema.get("items")
        if isinstance(item_schema, dict):
            for index, item in enumerate(instance):
                errors.extend(validate_instance(item, item_schema, f"{path}[{index}]"))

    if isinstance(instance, dict):
        min_properties = schema.get("minProperties")
        if isinstance(min_properties, int) and len(instance) < min_properties:
            errors.append(f"{path}: object has fewer than {min_properties} properties")

        property_names = schema.get("propertyNames", {})
        name_pattern = property_names.get("pattern") if isinstance(property_names, dict) else None
        if isinstance(name_pattern, str):
            for key in instance:
                if not re.search(name_pattern, key):
                    errors.append(f"{path}.{key}: property name does not match {name_pattern!r}")

        required = schema.get("required", [])
        if isinstance(required, list):
            for key in required:
                if key not in instance:
                    errors.append(f"{path}: missing required property {key!r}")

        properties = schema.get("properties", {})
        additional = schema.get("additionalProperties", True)
        if isinstance(properties, dict):
            for key, value in instance.items():
                child_path = f"{path}.{key}"
                if key in properties and isinstance(properties[key], dict):
                    errors.extend(validate_instance(value, properties[key], child_path))
                elif additional is False:
                    errors.append(f"{child_path}: additional property is not allowed")
                elif isinstance(additional, dict):
                    errors.extend(validate_instance(value, additional, child_path))

    return errors


def load_registry(registry_path: Path) -> dict[str, Any]:
    registry = load_json(registry_path)
    if not isinstance(registry, dict):
        raise ValueError("workflow contract registry root must be an object")
    if registry.get("schema_version") != 1:
        raise ValueError("workflow contract registry schema_version must be 1")
    return registry


def load_schemas(schema_dir: Path, registry: dict[str, Any]) -> tuple[dict[str, dict[str, Any]], list[ContractError]]:
    errors: list[ContractError] = []
    schemas: dict[str, dict[str, Any]] = {}
    schema_files = registry.get("schema_files", {})
    if not isinstance(schema_files, dict):
        return {}, [ContractError("registry", "schema_files must be an object")]

    for name, filename in sorted(schema_files.items()):
        if not isinstance(name, str) or not isinstance(filename, str):
            errors.append(ContractError("registry", "schema_files keys and values must be strings"))
            continue
        schema_path = schema_dir / filename
        if not schema_path.is_file():
            errors.append(ContractError("schema", f"{filename}: schema file is missing"))
            continue
        schema = load_json(schema_path)
        if not isinstance(schema, dict):
            errors.append(ContractError("schema", f"{filename}: schema root must be an object"))
            continue
        if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
            errors.append(ContractError("schema", f"{filename}: unsupported $schema"))
        if schema.get("type") != "object":
            errors.append(ContractError("schema", f"{filename}: root type must be object"))
        schemas[name] = schema

    return schemas, errors


def schema_tokens(schema: dict[str, Any]) -> list[str]:
    tokens: set[str] = set()
    required = schema.get("required", [])
    if isinstance(required, list):
        tokens.update(str(item) for item in required if item != "command")
    extra = schema.get("x_markdown_tokens", [])
    if isinstance(extra, list):
        tokens.update(str(item) for item in extra)
    return sorted(tokens)


def _markdown_example(text: str, heading: str) -> tuple[str | None, str | None]:
    heading_line = f"## {heading}"
    lines = text.splitlines()
    try:
        start = lines.index(heading_line) + 1
    except ValueError:
        return None, f"missing heading {heading!r}"
    end = len(lines)
    for index in range(start, len(lines)):
        if lines[index].startswith("## "):
            end = index
            break
    section = "\n".join(lines[start:end])
    match = JSON_BLOCK_RE.search(section)
    if not match:
        return None, f"missing JSON example under heading {heading!r}"
    return match.group("body"), None


def collect_contract_errors(
    repo_dir: Path = ROOT,
    schema_dir: Path = DEFAULT_SCHEMA_DIR,
    registry_path: Path = DEFAULT_REGISTRY,
) -> list[ContractError]:
    errors: list[ContractError] = []

    try:
        registry = load_registry(registry_path)
    except ValueError as exc:
        return [ContractError("registry", str(exc))]

    try:
        schemas, schema_errors = load_schemas(schema_dir, registry)
    except ValueError as exc:
        return [ContractError("schema", str(exc))]
    errors.extend(schema_errors)

    for example in registry.get("markdown_examples", []):
        if not isinstance(example, dict):
            errors.append(ContractError("registry", "markdown_examples entries must be objects"))
            continue
        schema_name = str(example.get("schema", ""))
        schema = schemas.get(schema_name)
        if schema is None:
            errors.append(ContractError("registry", f"unknown markdown example schema {schema_name!r}"))
            continue
        path = repo_dir / str(example.get("path", ""))
        heading = str(example.get("heading", ""))
        if not path.is_file():
            errors.append(ContractError("example", f"{path.relative_to(repo_dir)}: file is missing"))
            continue
        body, error = _markdown_example(path.read_text(encoding="utf-8"), heading)
        if error is not None:
            errors.append(ContractError("example", f"{path.relative_to(repo_dir)}: {error}"))
            continue
        try:
            payload = json.loads(body or "")
        except json.JSONDecodeError as exc:
            errors.append(
                ContractError(
                    "example",
                    f"{path.relative_to(repo_dir)}:{heading}: invalid JSON example: {exc.msg}",
                )
            )
            continue
        for message in validate_instance(payload, schema):
            errors.append(ContractError("example", f"{path.relative_to(repo_dir)}:{heading}: {message}"))

    legacy_markers = registry.get("legacy_routing_markers", [])
    consumers = registry.get("consumers", [])
    if not isinstance(consumers, list):
        errors.append(ContractError("registry", "consumers must be a list"))
        return errors

    for consumer in consumers:
        if not isinstance(consumer, dict):
            errors.append(ContractError("registry", "consumer entries must be objects"))
            continue
        rel_path = str(consumer.get("path", ""))
        path = repo_dir / rel_path
        if not path.is_file():
            errors.append(ContractError("consumer", f"{rel_path}: file is missing"))
            continue
        text = path.read_text(encoding="utf-8")

        for reference in consumer.get("references", []):
            if not isinstance(reference, str):
                errors.append(ContractError("registry", f"{rel_path}: references must be strings"))
                continue
            if reference not in text:
                errors.append(ContractError("consumer", f"{rel_path}: missing reference {reference!r}"))

        for schema_name in consumer.get("requires", []):
            if not isinstance(schema_name, str):
                errors.append(ContractError("registry", f"{rel_path}: requires entries must be strings"))
                continue
            schema = schemas.get(schema_name)
            if schema is None:
                errors.append(ContractError("registry", f"{rel_path}: unknown required schema {schema_name!r}"))
                continue
            for token in schema_tokens(schema):
                if token not in text:
                    errors.append(
                        ContractError(
                            "consumer",
                            f"{rel_path}: missing token {token!r} required by {schema_name}",
                        )
                    )

        if isinstance(legacy_markers, list):
            for marker in legacy_markers:
                if isinstance(marker, str) and marker in text:
                    errors.append(ContractError("consumer", f"{rel_path}: legacy routing marker {marker!r}"))

    return errors


def print_required(schema_name: str, schema_dir: Path, registry_path: Path) -> int:
    registry = load_registry(registry_path)
    schemas, errors = load_schemas(schema_dir, registry)
    if errors:
        for error in errors:
            print(error.format(), file=sys.stderr)
        return 1
    schema = schemas.get(schema_name)
    if schema is None:
        print(f"unknown schema: {schema_name}", file=sys.stderr)
        return 2
    for token in schema_tokens(schema):
        print(token)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate VibeGuard workflow contracts")
    parser.add_argument("--repo-dir", type=Path, default=ROOT)
    parser.add_argument("--schema-dir", type=Path, default=DEFAULT_SCHEMA_DIR)
    parser.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY)

    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("validate", help="Validate schemas, Markdown examples, and consumers")
    required = sub.add_parser("list-required", help="List Markdown tokens required by a schema")
    required.add_argument("schema_name")

    args = parser.parse_args(argv)
    repo_dir = args.repo_dir.resolve()
    schema_dir = args.schema_dir.resolve()
    registry = args.registry.resolve()

    if args.command == "list-required":
        return print_required(args.schema_name, schema_dir, registry)

    errors = collect_contract_errors(repo_dir, schema_dir, registry)
    if errors:
        print("FAIL: workflow contract drift detected", file=sys.stderr)
        for error in errors:
            print(f"- {error.format()}", file=sys.stderr)
        return 1
    print("OK: workflow contracts validate")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

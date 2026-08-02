"""Small fail-closed JSON Schema 2020-12 subset used by GH-704 verifiers."""

from __future__ import annotations

import json
import re
from typing import Any


SUPPORTED_KEYWORDS = {
    "$schema", "$id", "$defs", "$ref", "title", "description", "type",
    "additionalProperties", "required", "properties", "enum", "const",
    "minItems", "maxItems", "uniqueItems", "items", "prefixItems",
    "minimum", "minLength", "pattern", "allOf", "if", "then", "not",
}


class SchemaValidationError(ValueError):
    """The schema profile or supplied instance is invalid."""


def canonical_token(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def type_matches(value: Any, expected: str) -> bool:
    checks = {
        "object": lambda: isinstance(value, dict),
        "array": lambda: isinstance(value, list),
        "string": lambda: isinstance(value, str),
        "integer": lambda: isinstance(value, int) and not isinstance(value, bool),
        "number": lambda: isinstance(value, (int, float)) and not isinstance(value, bool),
        "boolean": lambda: isinstance(value, bool),
        "null": lambda: value is None,
    }
    if expected not in checks:
        raise SchemaValidationError(f"unsupported type {expected!r}")
    return checks[expected]()


def resolve_ref(root: dict[str, Any], reference: str) -> Any:
    if not reference.startswith("#/"):
        raise SchemaValidationError(f"non-local $ref {reference!r}")
    current: Any = root
    for token in reference[2:].split("/"):
        key = token.replace("~1", "/").replace("~0", "~")
        if not isinstance(current, dict) or key not in current:
            raise SchemaValidationError(f"unresolved $ref {reference!r}")
        current = current[key]
    return current


def check_keywords(schema: Any, location: str = "schema") -> None:
    if isinstance(schema, bool):
        return
    if not isinstance(schema, dict):
        raise SchemaValidationError(f"{location}: schema node must be object or boolean")
    unknown = set(schema) - SUPPORTED_KEYWORDS
    if unknown:
        raise SchemaValidationError(f"{location}: unsupported keywords {sorted(unknown)}")
    for container in ("$defs", "properties"):
        values = schema.get(container, {})
        if not isinstance(values, dict):
            raise SchemaValidationError(f"{location}.{container}: must be an object")
        for key, child in values.items():
            check_keywords(child, f"{location}.{container}.{key}")
    for key in ("items", "additionalProperties", "if", "then", "not"):
        if key in schema and isinstance(schema[key], (dict, bool)):
            check_keywords(schema[key], f"{location}.{key}")
    for key in ("prefixItems", "allOf"):
        if key in schema:
            children = schema[key]
            if not isinstance(children, list):
                raise SchemaValidationError(f"{location}.{key}: must be an array")
            for index, child in enumerate(children):
                check_keywords(child, f"{location}.{key}[{index}]")


def matches(instance: Any, schema: Any, root: dict[str, Any], location: str) -> bool:
    try:
        validate_instance_node(instance, schema, root, location)
    except SchemaValidationError:
        return False
    return True


def validate_instance_node(instance: Any, schema: Any, root: dict[str, Any], location: str) -> None:
    if schema is False:
        raise SchemaValidationError(f"{location}: rejected by false schema")
    if schema is True:
        return
    if "$ref" in schema:
        validate_instance_node(instance, resolve_ref(root, schema["$ref"]), root, location)
        if set(schema) - {"$ref", "title", "description"}:
            raise SchemaValidationError(f"{location}: $ref siblings are unsupported")
        return
    for child in schema.get("allOf", []):
        validate_instance_node(instance, child, root, location)
    if "if" in schema and matches(instance, schema["if"], root, location) and "then" in schema:
        validate_instance_node(instance, schema["then"], root, location)
    if "not" in schema and matches(instance, schema["not"], root, location):
        raise SchemaValidationError(f"{location}: rejected by not schema")
    expected = schema.get("type")
    if expected is not None:
        choices = expected if isinstance(expected, list) else [expected]
        if not choices or not all(isinstance(item, str) for item in choices):
            raise SchemaValidationError(f"{location}: malformed type")
        if not any(type_matches(instance, item) for item in choices):
            raise SchemaValidationError(f"{location}: expected {expected!r}")
    if "const" in schema and instance != schema["const"]:
        raise SchemaValidationError(f"{location}: const mismatch")
    if "enum" in schema and instance not in schema["enum"]:
        raise SchemaValidationError(f"{location}: value outside enum")
    if isinstance(instance, dict):
        properties = schema.get("properties", {})
        missing = set(schema.get("required", [])) - set(instance)
        if missing:
            raise SchemaValidationError(f"{location}: missing {sorted(missing)}")
        for key, value in instance.items():
            if key in properties:
                validate_instance_node(value, properties[key], root, f"{location}.{key}")
            else:
                additional = schema.get("additionalProperties", True)
                if additional is False:
                    raise SchemaValidationError(f"{location}: additional property {key!r}")
                if isinstance(additional, dict):
                    validate_instance_node(value, additional, root, f"{location}.{key}")
    if isinstance(instance, list):
        if len(instance) < schema.get("minItems", 0):
            raise SchemaValidationError(f"{location}: below minItems")
        if "maxItems" in schema and len(instance) > schema["maxItems"]:
            raise SchemaValidationError(f"{location}: above maxItems")
        if schema.get("uniqueItems") and len({canonical_token(item) for item in instance}) != len(instance):
            raise SchemaValidationError(f"{location}: duplicate items")
        prefix = schema.get("prefixItems", [])
        for index, child in enumerate(prefix[:len(instance)]):
            validate_instance_node(instance[index], child, root, f"{location}[{index}]")
        if "items" in schema:
            for index, item in enumerate(instance[len(prefix):], start=len(prefix)):
                validate_instance_node(item, schema["items"], root, f"{location}[{index}]")
    if isinstance(instance, str):
        if len(instance) < schema.get("minLength", 0):
            raise SchemaValidationError(f"{location}: below minLength")
        if "pattern" in schema and re.search(schema["pattern"], instance) is None:
            raise SchemaValidationError(f"{location}: pattern mismatch")
    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            raise SchemaValidationError(f"{location}: below minimum")


def validate_schema_instance(instance: Any, schema: dict[str, Any]) -> None:
    check_keywords(schema)
    validate_instance_node(instance, schema, schema, "model")

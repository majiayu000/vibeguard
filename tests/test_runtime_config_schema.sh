#!/usr/bin/env bash
# Runtime config schema, template, and boundary contract tests.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "${REPO_DIR}" <<'PY'
import copy
import json
import sys
from pathlib import Path

repo = Path(sys.argv[1])
schema = json.loads((repo / "schemas/vibeguard-runtime-config.schema.json").read_text(encoding="utf-8"))
template = json.loads((repo / "templates/vibeguard-config.json.example").read_text(encoding="utf-8"))

numeric_contract = {
    "u16.warn_limit": (0, 1_000_000),
    "u16.limit": (0, 1_000_000),
    "circuit_breaker.threshold": (0, 1_000_000),
    "circuit_breaker.cooldown_seconds": (0, 31_536_000),
    "circuit_breaker.lock_timeout_seconds": (0, 300),
    "w14.cooldown_seconds": (0, 31_536_000),
    "paralysis.threshold": (0, 1_000_000),
    "write_escalate_threshold": (0, 1_000_000),
    "learn.metrics_tail_bytes": (1, 268_435_456),
}
expected_paths = {"version", "write_mode", *numeric_contract}


def leaf_paths(node, prefix=""):
    paths = set()
    for key, child in node.get("properties", {}).items():
        path = f"{prefix}.{key}" if prefix else key
        if child.get("type") == "object":
            paths.update(leaf_paths(child, path))
        else:
            paths.add(path)
    return paths


def value_paths(node, prefix=""):
    paths = set()
    for key, child in node.items():
        path = f"{prefix}.{key}" if prefix else key
        if isinstance(child, dict):
            paths.update(value_paths(child, path))
        else:
            paths.add(path)
    return paths


def schema_at(path):
    node = schema
    for key in path.split("."):
        node = node["properties"][key]
    return node


def set_path(document, path, value):
    node = document
    parts = path.split(".")
    for key in parts[:-1]:
        node = node.setdefault(key, {})
    node[parts[-1]] = value


def validate(node, contract, path="$"):
    expected_type = contract.get("type")
    if expected_type == "object":
        if not isinstance(node, dict):
            return [f"{path}: type"]
        errors = []
        properties = contract.get("properties", {})
        if contract.get("additionalProperties") is False:
            for key in node.keys() - properties.keys():
                errors.append(f"{path}.{key}: unknown_field")
        for key, value in node.items():
            if key in properties:
                errors.extend(validate(value, properties[key], f"{path}.{key}"))
        return errors
    if expected_type == "integer":
        if isinstance(node, bool) or not isinstance(node, int):
            return [f"{path}: type"]
        if "const" in contract and node != contract["const"]:
            return [f"{path}: const"]
        if node < contract.get("minimum", node) or node > contract.get("maximum", node):
            return [f"{path}: range"]
        return []
    if expected_type == "string":
        if not isinstance(node, str):
            return [f"{path}: type"]
        if "enum" in contract and node not in contract["enum"]:
            return [f"{path}: enum"]
        return []
    return [f"{path}: unsupported_schema_type"]


def assert_valid(name, document):
    errors = validate(document, schema)
    if errors:
        raise AssertionError(f"{name} should be valid: {errors}")


def assert_invalid(name, document, category):
    errors = validate(document, schema)
    if not any(category in error for error in errors):
        raise AssertionError(f"{name} should fail with {category}: {errors}")


assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
assert schema["type"] == "object"
assert schema["additionalProperties"] is False
assert leaf_paths(schema) == expected_paths
assert value_paths(template) == expected_paths

for object_path in ["u16", "circuit_breaker", "w14", "paralysis", "learn"]:
    assert schema_at(object_path)["additionalProperties"] is False

for path, (minimum, maximum) in numeric_contract.items():
    field = schema_at(path)
    assert field == field | {"type": "integer", "minimum": minimum, "maximum": maximum}
    for label, value in [("minimum", minimum), ("maximum", maximum)]:
        fixture = {}
        set_path(fixture, path, value)
        assert_valid(f"{path} {label}", fixture)
    fixture = {}
    set_path(fixture, path, maximum + 1)
    assert_invalid(f"{path} max+1", fixture, "range")

for path in numeric_contract.keys() - {"learn.metrics_tail_bytes"}:
    fixture = {}
    set_path(fixture, path, 0)
    assert_valid(f"{path} zero", fixture)

assert_valid("empty object", {})
assert_valid("legacy version missing", {"write_mode": "block"})
assert_valid("explicit version one", {"version": 1})
assert_valid("partial nested object", {"u16": {"limit": 800}})
assert_valid("legacy warn-limit clamp", {"u16": {"warn_limit": 900, "limit": 800}})
assert_valid("published template", template)

for version in [0, 2]:
    assert_invalid(f"version {version}", {"version": version}, "const")
assert_invalid("learn zero", {"learn": {"metrics_tail_bytes": 0}}, "range")
assert_invalid("unknown root", {"secret_token": "do-not-print"}, "unknown_field")
assert_invalid("unknown nested", {"u16": {"typo": 1}}, "unknown_field")
assert_invalid("invalid write mode", {"write_mode": "invalid"}, "enum")
assert_invalid("numeric string", {"u16": {"limit": "800"}}, "type")
assert_invalid("boolean integer", {"paralysis": {"threshold": True}}, "type")

mutated_schema = copy.deepcopy(schema)
del mutated_schema["properties"]["write_escalate_threshold"]
assert leaf_paths(mutated_schema) != expected_paths
mutated_template = copy.deepcopy(template)
del mutated_template["learn"]["metrics_tail_bytes"]
assert value_paths(mutated_template) != expected_paths

print("runtime config schema: all named boundary, compatibility, and inventory checks passed")
PY

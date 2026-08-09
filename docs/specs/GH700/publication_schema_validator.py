#!/usr/bin/env python3
"""Draft 2020-12 subset evaluator used by the GH700 authority verifier.

Split out of `verify_publication_authority_api.py` to keep that file under the
U-16 ceiling. `make_validator` injects the caller's error type and uint64
semantic validator so this module stays free of verifier-specific imports.
"""

import re
from urllib.parse import urljoin


DRAFT_2020_12_TYPES = {
    "array", "boolean", "integer", "null", "number", "object", "string",
}
PLAIN_NAME = re.compile(r"^[A-Za-z_][-A-Za-z0-9._]*$")


def compile_draft_2020_12_schema(schema, error_type=ValueError):
    """Validate every used standard keyword against its 2020-12 meta shape.

    The verifier remains stdlib-only, so this is the schema-compilation part of
    the declared meta-schema rather than an instance-validation dependency. It
    follows every standard subschema-bearing keyword and rejects malformed
    keyword values before any model can short-circuit through a valid branch.
    """

    def fail(path, message):
        raise error_type(f"{path}: Draft 2020-12 meta-schema violation: {message}")

    def nonnegative_integer(value):
        return isinstance(value, int) and not isinstance(value, bool) and value >= 0

    anchors_by_resource = {}

    def schema_array(value, path, resource, nonempty=False):
        if not isinstance(value, list) or (nonempty and not value):
            fail(path, "schema array required")
        for index, child in enumerate(value):
            visit(child, f"{path}[{index}]", resource)

    def string_array(value, path, unique=False):
        if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
            fail(path, "string array required")
        if unique and len(value) != len(set(value)):
            fail(path, "array members must be unique")

    def schema_map(value, path, resource):
        if not isinstance(value, dict):
            fail(path, "schema object required")
        for key, child in value.items():
            if not isinstance(key, str):
                fail(path, "schema object keys must be strings")
            visit(child, f"{path}.{key}", resource)

    def visit(node, path, parent_resource):
        if isinstance(node, bool):
            return
        if not isinstance(node, dict):
            fail(path, "schema must be an object or boolean")
        resource = parent_resource
        if isinstance(node.get("$id"), str):
            resource = urljoin(parent_resource, node["$id"])
        for keyword in ("$schema", "$id", "$ref", "$dynamicRef", "$anchor", "$dynamicAnchor", "$comment", "title", "description", "format", "contentEncoding", "contentMediaType"):
            if keyword in node and not isinstance(node[keyword], str):
                fail(f"{path}.{keyword}", "string required")
        for keyword in ("$anchor", "$dynamicAnchor"):
            if keyword in node and PLAIN_NAME.fullmatch(node[keyword]) is None:
                fail(f"{path}.{keyword}", "plain-name anchor required")
            if keyword in node:
                names = anchors_by_resource.setdefault(resource, set())
                if node[keyword] in names:
                    fail(f"{path}.{keyword}", f"duplicate anchor in schema resource {resource}")
                names.add(node[keyword])
        if "$vocabulary" in node:
            vocabulary = node["$vocabulary"]
            if not isinstance(vocabulary, dict) or not all(isinstance(key, str) and isinstance(value, bool) for key, value in vocabulary.items()):
                fail(f"{path}.$vocabulary", "URI-to-boolean object required")
        if "type" in node:
            value = node["type"]
            if isinstance(value, str):
                if value not in DRAFT_2020_12_TYPES:
                    fail(f"{path}.type", "unknown simple type")
            elif isinstance(value, list):
                if not value or not all(isinstance(item, str) and item in DRAFT_2020_12_TYPES for item in value):
                    fail(f"{path}.type", "non-empty simple-type array required")
                if len(value) != len(set(value)):
                    fail(f"{path}.type", "type array members must be unique")
            else:
                fail(f"{path}.type", "string or simple-type array required")
        if "enum" in node:
            value = node["enum"]
            if not isinstance(value, list) or not value:
                fail(f"{path}.enum", "non-empty array required")
        for keyword in ("required",):
            if keyword in node:
                string_array(node[keyword], f"{path}.{keyword}", unique=True)
        if "dependentRequired" in node:
            value = node["dependentRequired"]
            if not isinstance(value, dict):
                fail(f"{path}.dependentRequired", "object required")
            for key, children in value.items():
                string_array(children, f"{path}.dependentRequired.{key}", unique=True)
        for keyword in ("minLength", "maxLength", "minItems", "maxItems", "minContains", "maxContains", "minProperties", "maxProperties"):
            if keyword in node and not nonnegative_integer(node[keyword]):
                fail(f"{path}.{keyword}", "non-negative integer required")
        for keyword in ("minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"):
            if keyword in node and (not isinstance(node[keyword], (int, float)) or isinstance(node[keyword], bool)):
                fail(f"{path}.{keyword}", "number required")
        if "multipleOf" in node and (not isinstance(node["multipleOf"], (int, float)) or isinstance(node["multipleOf"], bool) or node["multipleOf"] <= 0):
            fail(f"{path}.multipleOf", "positive number required")
        for keyword in ("uniqueItems", "deprecated", "readOnly", "writeOnly"):
            if keyword in node and not isinstance(node[keyword], bool):
                fail(f"{path}.{keyword}", "boolean required")
        if "pattern" in node:
            if not isinstance(node["pattern"], str):
                fail(f"{path}.pattern", "string required")
            try:
                re.compile(node["pattern"])
            except re.error as exc:
                fail(f"{path}.pattern", f"invalid regular expression: {exc}")
        for keyword in ("allOf", "anyOf", "oneOf", "prefixItems"):
            if keyword in node:
                schema_array(node[keyword], f"{path}.{keyword}", resource, nonempty=keyword != "prefixItems")
        for keyword in ("not", "if", "then", "else", "items", "contains", "additionalProperties", "unevaluatedProperties", "unevaluatedItems", "propertyNames", "contentSchema"):
            if keyword in node:
                visit(node[keyword], f"{path}.{keyword}", resource)
        for keyword in ("$defs", "properties", "patternProperties", "dependentSchemas"):
            if keyword in node:
                schema_map(node[keyword], f"{path}.{keyword}", resource)

    visit(schema, "$", "urn:gh700:anonymous-schema")


def make_validator(error_type, uint64, jcs):
    """Return (pointer, is_type, valid, validate) bound to the caller's types."""

    def pointer(root, ref):
        if not ref.startswith("#/"):
            raise error_type(f"non-local ref: {ref}")
        value = root
        for encoded in ref[2:].split("/"):
            key = encoded.replace("~1", "/").replace("~0", "~")
            if not isinstance(value, dict) or key not in value:
                raise error_type(f"dangling ref: {ref}")
            value = value[key]
        return value


    def is_type(value, expected):
        return {
            "object": isinstance(value, dict), "array": isinstance(value, list), "string": isinstance(value, str),
            "integer": isinstance(value, int) and not isinstance(value, bool), "number": isinstance(value, (int, float)) and not isinstance(value, bool),
            "boolean": isinstance(value, bool), "null": value is None,
        }[expected]


    def valid(value, schema, root):
        try:
            validate(value, schema, root)
            return True
        except error_type:
            return False


    def validate(value, schema, root, path="$"):
        if schema is True:
            return set()
        if schema is False or not isinstance(schema, dict):
            raise error_type(f"{path}: invalid/false schema")
        evaluated = set()
        if "$ref" in schema:
            evaluated.update(validate(value, pointer(root, schema["$ref"]), root, path))
        for child in schema.get("allOf", ()):
            evaluated.update(validate(value, child, root, path))
        if "anyOf" in schema:
            matches = []
            for child in schema["anyOf"]:
                try:
                    matches.append(validate(value, child, root, path))
                except error_type:
                    continue
            if not matches:
                raise error_type(f"{path}: no anyOf branch")
            for annotations in matches:
                evaluated.update(annotations)
        if "oneOf" in schema:
            matches = []
            for child in schema["oneOf"]:
                try:
                    matches.append(validate(value, child, root, path))
                except error_type:
                    continue
            if len(matches) != 1:
                raise error_type(f"{path}: oneOf cardinality mismatch")
            evaluated.update(matches[0])
        if "not" in schema and valid(value, schema["not"], root):
            raise error_type(f"{path}: forbidden by not")
        if "if" in schema:
            branch = schema.get("then") if valid(value, schema["if"], root) else schema.get("else")
            if branch is not None:
                evaluated.update(validate(value, branch, root, path))
        if "const" in schema and value != schema["const"]:
            raise error_type(f"{path}: const mismatch")
        if "enum" in schema and value not in schema["enum"]:
            raise error_type(f"{path}: enum mismatch")
        expected = schema.get("type")
        if isinstance(expected, str) and not is_type(value, expected):
            raise error_type(f"{path}: expected {expected}")
        if isinstance(expected, list) and not any(is_type(value, item) for item in expected):
            raise error_type(f"{path}: type union mismatch")
        if isinstance(value, dict):
            missing = [key for key in schema.get("required", ()) if key not in value]
            if missing:
                raise error_type(f"{path}: missing {missing}")
            props = schema.get("properties", {})
            for key, item in value.items():
                if key in props:
                    validate(item, props[key], root, f"{path}.{key}")
                    evaluated.add(key)
            if "additionalProperties" in schema:
                additional = set(value) - set(props)
                additional_schema = schema["additionalProperties"]
                if additional_schema is False and additional:
                    raise error_type(f"{path}: additional properties {sorted(additional)}")
                for key in additional:
                    validate(value[key], additional_schema, root, f"{path}.{key}")
                evaluated.update(additional)
            if "unevaluatedProperties" in schema:
                unevaluated = set(value) - evaluated
                unevaluated_schema = schema["unevaluatedProperties"]
                if unevaluated_schema is False and unevaluated:
                    raise error_type(f"{path}: unevaluated properties {sorted(unevaluated)}")
                for key in unevaluated:
                    validate(value[key], unevaluated_schema, root, f"{path}.{key}")
                evaluated.update(unevaluated)
        if isinstance(value, list):
            if len(value) < schema.get("minItems", 0) or len(value) > schema.get("maxItems", len(value)):
                raise error_type(f"{path}: array cardinality")
            if schema.get("uniqueItems") and len({jcs(item) for item in value}) != len(value):
                raise error_type(f"{path}: duplicate item")
            for index, item in enumerate(value):
                if "items" in schema:
                    validate(item, schema["items"], root, f"{path}[{index}]")
        if isinstance(value, str):
            if len(value) < schema.get("minLength", 0) or len(value) > schema.get("maxLength", len(value)):
                raise error_type(f"{path}: string length")
            if "pattern" in schema and re.search(schema["pattern"], value) is None:
                raise error_type(f"{path}: pattern mismatch")
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            if value < schema.get("minimum", value) or value > schema.get("maximum", value):
                raise error_type(f"{path}: numeric range")
        semantic_validator = schema.get("x-gh700-semantic-validator")
        if semantic_validator == "uint64":
            uint64(value, path)
        elif semantic_validator is not None:
            raise error_type(f"{path}: unknown semantic validator {semantic_validator}")
        return evaluated



    return pointer, is_type, valid, validate

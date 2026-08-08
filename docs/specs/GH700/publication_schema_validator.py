#!/usr/bin/env python3
"""Draft 2020-12 subset evaluator used by the GH700 authority verifier.

Split out of `verify_publication_authority_api.py` to keep that file under the
U-16 ceiling. `make_validator` injects the caller's error type and uint64
semantic validator so this module stays free of verifier-specific imports.
"""

import re


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

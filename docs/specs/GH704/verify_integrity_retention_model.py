#!/usr/bin/env python3
"""Validate the GH-704 W-02 integrity/retention model with the Python stdlib."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
import shlex
import sys
from pathlib import Path
from typing import Any, Callable


MODEL_PATH = Path(__file__).with_name("integrity_retention_model.json")
SCHEMA_PATH = Path(__file__).with_name("integrity_retention_model.schema.json")
AUTHORITY = "docs/specs/GH704/integrity_retention_model.json"
REQUIRED_EVIDENCE_CASES = {
    "crash_before_each_step",
    "crash_after_each_step",
    "illegal_transition_each_state",
}
EXPECTED_SELECTOR_IDS = {
    "hypothesis_observe", "attempt_observe", "failure_observe",
    "reset_observe", "retention_retire", "l1_evidence_publish",
}
SUPPORTED_SCHEMA_KEYWORDS = {
    "$schema", "$id", "$defs", "$ref", "title", "description", "type",
    "properties", "required", "additionalProperties", "items", "minItems",
    "maxItems", "uniqueItems", "enum", "const", "minimum", "minLength",
    "pattern",
}


class ModelError(ValueError):
    """The model, schema, or their relationship is invalid."""


def fail(message: str) -> None:
    raise ModelError(message)


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicate_keys)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        fail(f"{path}: {exc}")
    if not isinstance(value, dict):
        fail(f"{path}: top-level JSON value must be an object")
    return value


def canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def json_type_matches(value: Any, expected: str) -> bool:
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "null":
        return value is None
    fail(f"schema uses unsupported type {expected!r}")


def resolve_local_ref(root: dict[str, Any], reference: str) -> Any:
    if not reference.startswith("#/"):
        fail(f"schema uses non-local $ref {reference!r}")
    current: Any = root
    for token in reference[2:].split("/"):
        key = token.replace("~1", "/").replace("~0", "~")
        if not isinstance(current, dict) or key not in current:
            fail(f"schema has unresolved $ref {reference!r}")
        current = current[key]
    return current


def check_schema_keywords(schema: Any, location: str = "schema") -> None:
    if isinstance(schema, bool):
        return
    if not isinstance(schema, dict):
        fail(f"{location}: schema node must be object or boolean")
    unknown = set(schema) - SUPPORTED_SCHEMA_KEYWORDS
    if unknown:
        fail(f"{location}: unsupported JSON Schema keywords {sorted(unknown)}")
    for container in ("$defs", "properties"):
        values = schema.get(container, {})
        if not isinstance(values, dict):
            fail(f"{location}.{container}: must be an object")
        for key, child in values.items():
            check_schema_keywords(child, f"{location}.{container}.{key}")
    for key in ("items", "additionalProperties"):
        if key in schema and isinstance(schema[key], (dict, bool)):
            check_schema_keywords(schema[key], f"{location}.{key}")


def validate_json_schema(instance: Any, schema: Any, root: dict[str, Any], location: str = "model") -> None:
    if schema is False:
        fail(f"{location}: rejected by false schema")
    if schema is True:
        return
    if "$ref" in schema:
        validate_json_schema(instance, resolve_local_ref(root, schema["$ref"]), root, location)
        sibling_keys = set(schema) - {"$ref", "title", "description"}
        if sibling_keys:
            fail(f"{location}: $ref siblings are not supported by this schema profile")
        return
    expected_type = schema.get("type")
    if expected_type is not None:
        expected_types = expected_type if isinstance(expected_type, list) else [expected_type]
        if not expected_types or not all(isinstance(item, str) for item in expected_types):
            fail(f"{location}: malformed schema type")
        if not any(json_type_matches(instance, item) for item in expected_types):
            fail(f"{location}: expected type {expected_type!r}, got {type(instance).__name__}")
    if "const" in schema and instance != schema["const"]:
        fail(f"{location}: value does not match const")
    if "enum" in schema and instance not in schema["enum"]:
        fail(f"{location}: value is outside enum")
    if isinstance(instance, dict):
        properties = schema.get("properties", {})
        required = schema.get("required", [])
        if not isinstance(required, list) or not all(isinstance(item, str) for item in required):
            fail(f"{location}: malformed required keyword")
        missing = set(required) - set(instance)
        if missing:
            fail(f"{location}: missing required properties {sorted(missing)}")
        for key, value in instance.items():
            if key in properties:
                validate_json_schema(value, properties[key], root, f"{location}.{key}")
                continue
            additional = schema.get("additionalProperties", True)
            if additional is False:
                fail(f"{location}: additional property {key!r} is forbidden")
            if isinstance(additional, dict):
                validate_json_schema(value, additional, root, f"{location}.{key}")
    if isinstance(instance, list):
        if "minItems" in schema and len(instance) < schema["minItems"]:
            fail(f"{location}: array shorter than minItems")
        if "maxItems" in schema and len(instance) > schema["maxItems"]:
            fail(f"{location}: array longer than maxItems")
        if schema.get("uniqueItems") is True:
            encoded = [canonical_json(item) for item in instance]
            if len(encoded) != len(set(encoded)):
                fail(f"{location}: array items are not unique")
        if "items" in schema:
            for index, item in enumerate(instance):
                validate_json_schema(item, schema["items"], root, f"{location}[{index}]")
    if isinstance(instance, str):
        if "minLength" in schema and len(instance) < schema["minLength"]:
            fail(f"{location}: string shorter than minLength")
        if "pattern" in schema and re.search(schema["pattern"], instance) is None:
            fail(f"{location}: string does not match pattern")
    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            fail(f"{location}: number is below minimum")


def unique_index(items: list[dict[str, Any]], location: str) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    for item in items:
        item_id = item["id"]
        if item_id in result:
            fail(f"{location}: duplicate id {item_id}")
        result[item_id] = item
    return result


def canonical_inventory(epoch: dict[str, Any]) -> dict[str, Any]:
    sources = sorted(epoch["source_ids"])
    projects = sorted(
        ({"project_id": item["project_id"], "source_ids": sorted(item["source_ids"])} for item in epoch["projects"]),
        key=lambda item: item["project_id"],
    )
    return {
        "inventory_version": epoch["inventory_version"],
        "source_ids": sources,
        "projects": projects,
    }


def inventory_digest(epoch: dict[str, Any]) -> str:
    return hashlib.sha256(canonical_json(canonical_inventory(epoch)).encode("utf-8")).hexdigest()


def tuple_id(template_id: str, project_id: str, source_id: str) -> str:
    binding = canonical_json([template_id, project_id, source_id]).encode("utf-8")
    return f"tuple_{hashlib.sha256(binding).hexdigest()}"


def expand_tuples(model: dict[str, Any]) -> list[dict[str, Any]]:
    templates = sorted(model["tuple_templates"], key=lambda item: item["id"])
    projects = canonical_inventory(model["policy_epoch"])["projects"]
    expanded: list[dict[str, Any]] = []
    for template in templates:
        for project in projects:
            for source_id in project["source_ids"]:
                expanded.append({
                    "id": tuple_id(template["id"], project["project_id"], source_id),
                    "template_id": template["id"],
                    "evidence_kind": template["evidence_kind"],
                    "source_id": source_id,
                    "project_id": project["project_id"],
                    "retention_class": template["retention_class"],
                })
    return expanded


def validate_dag(steps: list[dict[str, Any]], location: str) -> dict[str, dict[str, Any]]:
    indexed = unique_index(steps, location)
    for step_id, step in indexed.items():
        unknown = set(step["depends_on"]) - indexed.keys()
        if unknown:
            fail(f"{location}.{step_id}: unknown dependencies {sorted(unknown)}")
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(step_id: str) -> None:
        if step_id in visiting:
            fail(f"{location}: cycle at {step_id}")
        if step_id in visited:
            return
        visiting.add(step_id)
        for dependency in indexed[step_id]["depends_on"]:
            visit(dependency)
        visiting.remove(step_id)
        visited.add(step_id)

    for step_id in indexed:
        visit(step_id)
    return indexed


def validate_inventory(model: dict[str, Any]) -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, Any]]]:
    epoch = model["policy_epoch"]
    if len(epoch["source_ids"]) != len(set(epoch["source_ids"])):
        fail("model.policy_epoch.source_ids: duplicates are forbidden")
    projects: dict[str, dict[str, Any]] = {}
    for project in epoch["projects"]:
        project_id = project["project_id"]
        if project_id in projects:
            fail(f"model.policy_epoch.projects: duplicate id {project_id}")
        projects[project_id] = project
    source_ids = set(epoch["source_ids"])
    for project_id, project in projects.items():
        unknown = set(project["source_ids"]) - source_ids
        if unknown:
            fail(f"model.policy_epoch.projects.{project_id}: unknown sources {sorted(unknown)}")
    if epoch["inventory_digest"] != inventory_digest(epoch):
        fail("model.policy_epoch.inventory_digest: does not bind the closed inventory")
    templates = unique_index(model["tuple_templates"], "model.tuple_templates")
    expected = expand_tuples(model)
    if model["tuples"] != expected:
        fail("model.tuples: not the deterministic complete policy-epoch expansion")
    tuples = unique_index(model["tuples"], "model.tuples")
    binding_count = len(templates) * sum(len(project["source_ids"]) for project in projects.values())
    if len(tuples) != binding_count:
        fail("model.tuples: expansion is not bijective")
    return templates, tuples


def validate_edges_and_evidence(
    model: dict[str, Any], templates: dict[str, dict[str, Any]], tuples: dict[str, dict[str, Any]]
) -> tuple[int, int, int]:
    selectors = unique_index(model["selectors"], "model.selectors")
    if set(selectors) != EXPECTED_SELECTOR_IDS:
        fail("model.selectors: selector inventory is not the closed exact set")
    for selector_id, selector in selectors.items():
        expected_argv = ("bash", "tests/hooks/test_runtime_rule_signals.sh", selector_id)
        try:
            actual_argv = tuple(shlex.split(selector["command"], posix=True))
        except ValueError as exc:
            fail(f"model.selectors.{selector_id}: command cannot be parsed: {exc}")
        if actual_argv != expected_argv or selector["command"] != " ".join(expected_argv):
            fail(f"model.selectors.{selector_id}: command differs from the canonical exact invocation")
    state_universe = set(model["state_universe"])
    edges = unique_index(model["edges"], "model.edges")
    transition_index: dict[tuple[str, str], dict[str, Any]] = {}
    relation_keys: set[tuple[str, str, str, str, str, str, str]] = set()
    for edge_id, edge in edges.items():
        unknown_templates = set(edge["tuple_template_ids"]) - templates.keys()
        if unknown_templates:
            fail(f"model.edges.{edge_id}: unknown tuple templates {sorted(unknown_templates)}")
        transitions = unique_index(edge["transitions"], f"model.edges.{edge_id}.transitions")
        for transition_id, transition in transitions.items():
            if transition["selector_id"] not in selectors:
                fail(f"model.edges.{edge_id}.{transition_id}: unknown selector")
            if set(transition["from_states"]) - state_universe or transition["to_state"] not in state_universe:
                fail(f"model.edges.{edge_id}.{transition_id}: transition state outside universe")
            expected_illegal = state_universe - set(transition["from_states"])
            if set(transition["illegal_from_states"]) != expected_illegal:
                fail(f"model.edges.{edge_id}.{transition_id}: illegal transition states are incomplete")
            steps = validate_dag(transition["steps"], f"model.edges.{edge_id}.{transition_id}.steps")
            transition_index[(edge_id, transition_id)] = transition
            applicable = [item for item in tuples.values() if item["template_id"] in edge["tuple_template_ids"]]
            for exact_tuple in applicable:
                prefix = (edge_id, exact_tuple["id"], transition["selector_id"], transition_id)
                for step_id, step in steps.items():
                    relation_keys.add(prefix + ("crash_before", step_id, step["crash_before"]))
                    relation_keys.add(prefix + ("crash_after", step_id, step["crash_after"]))
                for illegal_state in transition["illegal_from_states"]:
                    relation_keys.add(prefix + ("illegal_transition", illegal_state, "rejected_no_write"))
    bindings: dict[tuple[str, str], dict[str, Any]] = {}
    for binding in model["evidence_bindings"]:
        key = (binding["edge_id"], binding["transition_id"])
        if key in bindings:
            fail(f"model.evidence_bindings: duplicate relation binding {key}")
        transition = transition_index.get(key)
        edge = edges.get(binding["edge_id"])
        if transition is None or edge is None:
            fail(f"model.evidence_bindings: unknown edge/transition {key}")
        if binding["selector_id"] != transition["selector_id"]:
            fail(f"model.evidence_bindings.{key}: selector relation mismatch")
        if binding["tuple_template_ids"] != edge["tuple_template_ids"]:
            fail(f"model.evidence_bindings.{key}: tuple relation is not exact")
        if set(binding["required_cases"]) != REQUIRED_EVIDENCE_CASES:
            fail(f"model.evidence_bindings.{key}: crash/illegal evidence is incomplete")
        bindings[key] = binding
    if bindings.keys() != transition_index.keys():
        fail("model.evidence_bindings: every edge transition needs exactly one relational binding")
    expected_relations = sum(
        len([item for item in tuples.values() if item["template_id"] in edges[edge_id]["tuple_template_ids"]])
        * (2 * len(transition["steps"]) + len(transition["illegal_from_states"]))
        for (edge_id, _), transition in transition_index.items()
    )
    if len(relation_keys) != expected_relations:
        fail("model.evidence_bindings: expanded relation keys are not bijective")
    return len(edges), len(transition_index), len(relation_keys)


def validate_l1_order(model: dict[str, Any]) -> None:
    contract = model["l1_order_contract"]
    edge = next((item for item in model["edges"] if item["id"] == contract["edge_id"]), None)
    if edge is None:
        fail("model.l1_order_contract: edge missing")
    transition = next((item for item in edge["transitions"] if item["id"] == contract["transition_id"]), None)
    if transition is None:
        fail("model.l1_order_contract: transition missing")
    steps = unique_index(transition["steps"], "model.l1_order_contract.steps")
    ordered = contract["ordered_steps"]
    expected = ["prepared_write", "prepared_fsync", "row_write", "row_fsync", "manifest_publish"]
    if ordered != expected or set(steps) != set(expected):
        fail("model.l1_order_contract: exact write-fsync-publish step inventory changed")
    for index, step_id in enumerate(ordered):
        expected_dependencies = [] if index == 0 else [ordered[index - 1]]
        if steps[step_id]["depends_on"] != expected_dependencies:
            fail(f"model.l1_order_contract: {step_id} bypasses the full predecessor order")


def validate_model(model: dict[str, Any], schema: dict[str, Any]) -> dict[str, int]:
    check_schema_keywords(schema)
    validate_json_schema(model, schema, schema)
    if model["authority"] != AUTHORITY:
        fail("model.authority: JSON must name itself as the sole W-02 machine authority")
    templates, tuples = validate_inventory(model)
    edges, transitions, relations = validate_edges_and_evidence(model, templates, tuples)
    validate_l1_order(model)
    return {
        "sources": len(model["policy_epoch"]["source_ids"]),
        "projects": len(model["policy_epoch"]["projects"]),
        "templates": len(templates),
        "tuples": len(tuples),
        "edges": edges,
        "transitions": transitions,
        "selectors": len(model["selectors"]),
        "expanded_evidence_relations": relations,
    }


def refresh_epoch_expansion(candidate: dict[str, Any]) -> None:
    candidate["policy_epoch"]["inventory_digest"] = inventory_digest(candidate["policy_epoch"])
    candidate["tuples"] = expand_tuples(candidate)


def self_test(model: dict[str, Any], schema: dict[str, Any]) -> tuple[int, int]:
    negative_cases: list[tuple[str, Callable[[dict[str, Any]], None]]] = [
        ("unknown_top_level", lambda value: value.__setitem__("unknown", True)),
        ("schema_tuples_type_string", lambda value: value.__setitem__("tuples", "not-an-array")),
        ("boolean_version", lambda value: value.__setitem__("version", True)),
        ("unknown_project_source", lambda value: value["policy_epoch"]["projects"][0]["source_ids"].append("unknown_source")),
        ("inventory_digest_drift", lambda value: value["policy_epoch"]["source_ids"].append("source_gamma")),
        ("selector_comment_command", lambda value: value["selectors"][0].__setitem__("command", "true # hypothesis_observe")),
        ("missing_expanded_tuple", lambda value: value["tuples"].pop()),
        ("extra_expanded_tuple", lambda value: value["tuples"].append(copy.deepcopy(value["tuples"][0]))),
        ("missing_relation_binding", lambda value: value["evidence_bindings"].pop()),
        ("relation_selector_rewrite", lambda value: value["evidence_bindings"][0].__setitem__("selector_id", "retention_retire")),
        ("relation_tuple_gap", lambda value: value["evidence_bindings"][0]["tuple_template_ids"].pop()),
        ("illegal_transition_gap", lambda value: value["edges"][0]["transitions"][0]["illegal_from_states"].pop()),
        ("fault_case_gap", lambda value: value["evidence_bindings"][0]["required_cases"].pop()),
        ("boundary_cycle", lambda value: value["edges"][0]["transitions"][0]["steps"][0]["depends_on"].append("reservation_fsync")),
        ("l1_publish_depends_on_prepared", lambda value: value["edges"][-1]["transitions"][0]["steps"][-1].__setitem__("depends_on", ["prepared_fsync"])),
        ("l1_row_fsync_bypass", lambda value: value["edges"][-1]["transitions"][0]["steps"][3].__setitem__("depends_on", ["prepared_fsync"])),
    ]
    for name, mutate in negative_cases:
        candidate = copy.deepcopy(model)
        mutate(candidate)
        try:
            validate_model(candidate, schema)
        except ModelError:
            continue
        fail(f"self-test {name}: invalid mutation was accepted")
    growth = copy.deepcopy(model)
    growth["policy_epoch"]["source_ids"].append("source_gamma")
    growth["policy_epoch"]["projects"].append({"project_id": "project_gamma", "source_ids": ["source_gamma"]})
    refresh_epoch_expansion(growth)
    growth_counts = validate_model(growth, schema)
    if growth_counts["tuples"] != len(model["tuples"]) + len(model["tuple_templates"]):
        fail("self-test runtime_inventory_growth: finite expansion is incomplete")
    reordered = copy.deepcopy(model)
    reordered["policy_epoch"]["source_ids"].reverse()
    reordered["policy_epoch"]["projects"].reverse()
    for project in reordered["policy_epoch"]["projects"]:
        project["source_ids"].reverse()
    refresh_epoch_expansion(reordered)
    validate_model(reordered, schema)
    empty = copy.deepcopy(model)
    empty["policy_epoch"]["source_ids"] = []
    empty["policy_epoch"]["projects"] = []
    refresh_epoch_expansion(empty)
    empty_counts = validate_model(empty, schema)
    if empty_counts["tuples"] != 0 or empty_counts["expanded_evidence_relations"] != 0:
        fail("self-test empty_runtime_inventory: empty finite expansion is not closed")
    return len(negative_cases), 3


def format_counts(counts: dict[str, int]) -> str:
    return " ".join(f"{key}={value}" for key, value in counts.items())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, default=MODEL_PATH)
    parser.add_argument("--schema", type=Path, default=SCHEMA_PATH)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    try:
        model = load_json(args.model)
        schema = load_json(args.schema)
        counts = validate_model(model, schema)
        print(f"INTEGRITY_RETENTION_MODEL_OK version={model['version']} {format_counts(counts)}")
        if args.self_test:
            negative, positive = self_test(model, schema)
            print(f"INTEGRITY_RETENTION_MODEL_SELF_TEST_OK negative={negative} positive={positive}")
    except ModelError as exc:
        print(f"INTEGRITY_RETENTION_MODEL_ERROR {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

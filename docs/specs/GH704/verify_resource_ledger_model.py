#!/usr/bin/env python3
"""Verify the closed GH-704 ResourceLedger machine model with no third-party deps."""

from __future__ import annotations

import argparse
import copy
import itertools
import json
import sys
from pathlib import Path
from typing import Any, Callable

from json_schema_subset import SchemaValidationError, validate_schema_instance
from resource_ledger_epoch import EpochModelError, positive_expansion_model, validate_epoch_instance


MODEL_PATH = Path(__file__).with_name("resource_ledger_model.json")
SCHEMA_PATH = Path(__file__).with_name("resource_ledger_model.schema.json")

RESOURCE_KINDS = {
    "registry_live_slot",
    "keyed_receipt_slot",
    "completed_index",
    "outbox",
    "quarantine_frozen_lag",
    "success_history",
    "global_admin",
    "project_wal_live",
    "project_wal_scratch",
    "derived_log_live",
    "derived_log_scratch",
    "canonical_journal_live",
    "canonical_journal_scratch",
}
DIMENSIONS = [
    "entries",
    "bytes",
    "segments",
    "segment_bytes",
    "per_source_quota",
    "physical_bytes",
]
SELECTOR_IDS = {
    "wal_compaction_capacity_transfer",
    "allocator_wal_capacity_contract",
    "canonical_journal_gc_scratch_capacity",
    "project_wal_pre_provider_terminal_closure",
    "canonical_journal_l1_entitlement_capacity_one",
    "capacity_ledger_model_check",
    "reservation_bundle_terminal_closure",
    "success_history_gc_release_receipt",
    "derived_log_compaction_capacity_transfer",
    "admin_adoption_capacity_preflight",
    "compaction_role_exchange_capacity_one",
    "admin_adoption_scratch_capacity_one",
    "resource_kind_edge_coverage",
}
ROOT_COVERAGE = {"live_scratch_ab", "l1_semantic", "admin_adoption", "all_sources"}
EXPECTED_KEYS = {"crash_before", "crash_after", "lost_response_after"}
FORBIDDEN_LITERAL_STRINGS = {"N/A", "all_declared", "*"}
FORBIDDEN_FRAGMENTS = ("<", ">", "|")
EXPECTED_SELECTOR_COMMANDS = {
    "wal_compaction_capacity_transfer": "bash tests/hooks/test_runtime_rule_signals.sh wal_compaction_capacity_transfer",
    "allocator_wal_capacity_contract": "bash tests/hooks/test_runtime_rule_signals.sh allocator_wal_capacity_contract",
    "canonical_journal_gc_scratch_capacity": "bash tests/test_gc_logs_rotation.sh canonical_journal_gc_scratch_capacity",
    "project_wal_pre_provider_terminal_closure": "bash tests/hooks/test_runtime_rule_signals.sh project_wal_pre_provider_terminal_closure",
    "canonical_journal_l1_entitlement_capacity_one": "bash tests/test_gc_logs_concurrent.sh canonical_journal_l1_entitlement_capacity_one",
    "capacity_ledger_model_check": "python3 docs/specs/GH704/verify_resource_ledger_model.py",
    "reservation_bundle_terminal_closure": "bash tests/hooks/test_runtime_rule_signals.sh reservation_bundle_terminal_closure",
    "success_history_gc_release_receipt": "bash tests/hooks/test_runtime_rule_signals.sh success_history_gc_release_receipt",
    "derived_log_compaction_capacity_transfer": "bash tests/hooks/test_runtime_rule_signals.sh derived_log_compaction_capacity_transfer",
    "admin_adoption_capacity_preflight": "bash tests/hooks/test_runtime_rule_signals.sh admin_adoption_capacity_preflight",
    "compaction_role_exchange_capacity_one": "bash tests/hooks/test_runtime_rule_signals.sh compaction_role_exchange_capacity_one",
    "admin_adoption_scratch_capacity_one": "bash tests/hooks/test_runtime_rule_signals.sh admin_adoption_scratch_capacity_one",
    "resource_kind_edge_coverage": "bash tests/hooks/test_runtime_rule_signals.sh resource_kind_edge_coverage",
}


class ModelError(ValueError):
    """The model violates a closed GH-704 ResourceLedger contract."""


def fail(message: str) -> None:
    raise ModelError(message)


def load_resource_ledger_json(path: Path) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot load {path}: {exc}")
    if not isinstance(value, dict):
        fail(f"{path}: top-level value must be an object")
    return value


def object_keys(
    value: Any,
    location: str,
    required: set[str],
    optional: set[str] | None = None,
) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{location}: expected object")
    allowed = required | (optional or set())
    missing = required - value.keys()
    unknown = value.keys() - allowed
    if missing:
        fail(f"{location}: missing fields {sorted(missing)}")
    if unknown:
        fail(f"{location}: unknown fields {sorted(unknown)}")
    return value


def list_value(value: Any, location: str, *, nonempty: bool = True) -> list[Any]:
    if not isinstance(value, list):
        fail(f"{location}: expected array")
    if nonempty and not value:
        fail(f"{location}: expected nonempty array")
    return value


def string_value(value: Any, location: str) -> str:
    if not isinstance(value, str) or not value:
        fail(f"{location}: expected nonempty string")
    return value


def integer_value(value: Any, location: str, *, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        fail(f"{location}: expected integer, boolean is forbidden")
    if value < minimum:
        fail(f"{location}: expected integer >= {minimum}")
    return value


def unique_index(items: Any, location: str) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    for position, item in enumerate(list_value(items, location)):
        if not isinstance(item, dict):
            fail(f"{location}[{position}]: expected object")
        identifier = string_value(item.get("id"), f"{location}[{position}].id")
        if identifier in result:
            fail(f"{location}: duplicate id {identifier}")
        result[identifier] = item
    return result


def unique_strings(value: Any, location: str, *, nonempty: bool = True) -> list[str]:
    items = list_value(value, location, nonempty=nonempty)
    strings = [string_value(item, f"{location}[{index}]") for index, item in enumerate(items)]
    if len(strings) != len(set(strings)):
        fail(f"{location}: duplicate values")
    return strings


def reject_symbolic_values(value: Any, location: str = "model") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            reject_symbolic_values(child, f"{location}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            reject_symbolic_values(child, f"{location}[{index}]")
    elif isinstance(value, str):
        if value in FORBIDDEN_LITERAL_STRINGS or any(fragment in value for fragment in FORBIDDEN_FRAGMENTS):
            fail(f"{location}: placeholder, pseudo-N/A, or unexpanded symbol is forbidden: {value!r}")


def validate_schema(schema: dict[str, Any]) -> None:
    if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
        fail("schema: expected JSON Schema draft 2020-12")
    if schema.get("additionalProperties") is not False:
        fail("schema: top-level additionalProperties must be false")
    definitions = schema.get("$defs")
    if not isinstance(definitions, dict):
        fail("schema: missing $defs")
    kind_schema = definitions.get("resource_kind")
    if not isinstance(kind_schema, dict) or set(kind_schema.get("enum", [])) != RESOURCE_KINDS:
        fail("schema: resource_kind enum is not the closed 13-kind inventory")
    for name, definition in definitions.items():
        if isinstance(definition, dict) and definition.get("type") == "object":
            if definition.get("additionalProperties") is not False:
                fail(f"schema.$defs.{name}: object must reject unknown fields")


def validate_schema_instance_or_fail(model: dict[str, Any], schema: dict[str, Any]) -> None:
    try:
        validate_schema_instance(model, schema)
    except SchemaValidationError as exc:
        fail(f"schema instance validation failed: {exc}")


def validate_tuple_model(model: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    exact_scopes = set(unique_strings(model["exact_scopes"], "model.exact_scopes"))
    grammar = object_keys(
        model["tuple_expansion_grammar"],
        "model.tuple_expansion_grammar",
        {"version", "selector_reference", "finite_only", "forbidden_tokens"},
    )
    integer_value(grammar["version"], "model.tuple_expansion_grammar.version", minimum=1)
    if grammar["selector_reference"] != "tuple_set_id" or grammar["finite_only"] is not True:
        fail("model.tuple_expansion_grammar: only finite tuple_set_id references are legal")
    expected_forbidden = {
        "angle_bracket_placeholder",
        "wildcard",
        "pipe_alternative",
        "pseudo_not_applicable",
        "symbolic_all",
    }
    if set(unique_strings(grammar["forbidden_tokens"], "model.tuple_expansion_grammar.forbidden_tokens")) != expected_forbidden:
        fail("model.tuple_expansion_grammar: incomplete forbidden-token classes")

    tuples = unique_index(model["tuples"], "model.tuples")
    triples: set[tuple[str, str, str]] = set()
    kinds_seen: set[str] = set()
    for tuple_id, item in tuples.items():
        object_keys(
            item,
            f"model.tuples.{tuple_id}",
            {"id", "resource_kind", "scope_id", "quota_partition_id", "root_id", "physical_domain", "maxima"},
        )
        kind = string_value(item["resource_kind"], f"model.tuples.{tuple_id}.resource_kind")
        if kind not in RESOURCE_KINDS:
            fail(f"model.tuples.{tuple_id}: unknown resource kind {kind}")
        scope = string_value(item["scope_id"], f"model.tuples.{tuple_id}.scope_id")
        if scope not in exact_scopes:
            fail(f"model.tuples.{tuple_id}: scope is not in exact_scopes: {scope}")
        partition = string_value(item["quota_partition_id"], f"model.tuples.{tuple_id}.quota_partition_id")
        triple = (kind, scope, partition)
        if triple in triples:
            fail(f"model.tuples.{tuple_id}: duplicate immutable tuple {triple}")
        triples.add(triple)
        kinds_seen.add(kind)
        string_value(item["root_id"], f"model.tuples.{tuple_id}.root_id")
        string_value(item["physical_domain"], f"model.tuples.{tuple_id}.physical_domain")
        maxima = object_keys(item["maxima"], f"model.tuples.{tuple_id}.maxima", set(DIMENSIONS))
        for dimension in DIMENSIONS:
            integer_value(maxima[dimension], f"model.tuples.{tuple_id}.maxima.{dimension}")
        if maxima["physical_bytes"] == 0:
            fail(f"model.tuples.{tuple_id}: tuple physical_bytes maximum must be positive")
    if kinds_seen != RESOURCE_KINDS:
        fail(f"model.tuples: resource-kind coverage mismatch: {sorted(RESOURCE_KINDS - kinds_seen)}")

    tuple_sets = unique_index(model["tuple_sets"], "model.tuple_sets")
    for set_id, tuple_set in tuple_sets.items():
        object_keys(tuple_set, f"model.tuple_sets.{set_id}", {"id", "tuple_ids"})
        tuple_ids = unique_strings(tuple_set["tuple_ids"], f"model.tuple_sets.{set_id}.tuple_ids")
        unknown = set(tuple_ids) - tuples.keys()
        if unknown:
            fail(f"model.tuple_sets.{set_id}: unknown tuple ids {sorted(unknown)}")
    if set(tuple_sets.get("all_exact_tuples", {}).get("tuple_ids", [])) != tuples.keys():
        fail("model.tuple_sets.all_exact_tuples: must enumerate every exact tuple once")
    return tuples, tuple_sets


def validate_roots(
    model: dict[str, Any], tuples: dict[str, Any]
) -> tuple[dict[str, Any], dict[str, Any], int]:
    components = unique_index(model["root_components"], "model.root_components")
    roots = unique_index(model["roots"], "model.roots")
    tuple_components: dict[str, str] = {}
    for component_id, component in components.items():
        object_keys(
            component,
            f"model.root_components.{component_id}",
            {"id", "root_id", "physical_domain", "component_type", "max_physical_bytes"},
            {"tuple_id", "metadata_role"},
        )
        integer_value(
            component["max_physical_bytes"],
            f"model.root_components.{component_id}.max_physical_bytes",
            minimum=1,
        )
        component_type = component["component_type"]
        if component_type == "tuple":
            if "tuple_id" not in component or "metadata_role" in component:
                fail(f"model.root_components.{component_id}: tuple component shape mismatch")
            tuple_id = component["tuple_id"]
            if tuple_id not in tuples:
                fail(f"model.root_components.{component_id}: unknown tuple {tuple_id}")
            if tuple_id in tuple_components:
                fail(f"model.root_components: tuple {tuple_id} has multiple physical components")
            tuple_components[tuple_id] = component_id
            tuple_item = tuples[tuple_id]
            if component["root_id"] != tuple_item["root_id"] or component["physical_domain"] != tuple_item["physical_domain"]:
                fail(f"model.root_components.{component_id}: tuple/root/domain mapping mismatch")
            if component["max_physical_bytes"] != tuple_item["maxima"]["physical_bytes"]:
                fail(f"model.root_components.{component_id}: physical maximum differs from tuple")
        elif component_type == "metadata":
            if "metadata_role" not in component or "tuple_id" in component:
                fail(f"model.root_components.{component_id}: metadata component shape mismatch")
        else:
            fail(f"model.root_components.{component_id}: unknown component_type {component_type}")
    if tuple_components.keys() != tuples.keys():
        fail("model.root_components: every exact tuple must map to exactly one component")

    component_membership: dict[str, str] = {}
    for root_id, root in roots.items():
        object_keys(root, f"model.roots.{root_id}", {"id", "physical_domain", "max_physical_bytes", "component_ids"})
        maximum = integer_value(root["max_physical_bytes"], f"model.roots.{root_id}.max_physical_bytes", minimum=1)
        component_ids = unique_strings(root["component_ids"], f"model.roots.{root_id}.component_ids")
        for component_id in component_ids:
            if component_id not in components:
                fail(f"model.roots.{root_id}: unknown component {component_id}")
            if component_id in component_membership:
                fail(f"model.roots: component {component_id} belongs to multiple roots")
            component_membership[component_id] = root_id
            component = components[component_id]
            if component["root_id"] != root_id or component["physical_domain"] != root["physical_domain"]:
                fail(f"model.roots.{root_id}: component {component_id} root/domain mismatch")
        declared_sum = sum(components[item]["max_physical_bytes"] for item in component_ids)
        if declared_sum != maximum:
            fail(f"model.roots.{root_id}: max {maximum} must equal all-component sum {declared_sum}")
    if component_membership.keys() != components.keys():
        fail("model.roots: every component must belong to exactly one root")

    scenarios = unique_index(model["root_capacity_scenarios"], "model.root_capacity_scenarios")
    coverage: set[str] = set()
    cartesian_cases = 0
    for scenario_id, scenario in scenarios.items():
        object_keys(
            scenario,
            f"model.root_capacity_scenarios.{scenario_id}",
            {"id", "root_id", "required_full_component_ids", "cartesian_axes", "coverage"},
        )
        root_id = scenario["root_id"]
        if root_id not in roots:
            fail(f"model.root_capacity_scenarios.{scenario_id}: unknown root {root_id}")
        required = unique_strings(
            scenario["required_full_component_ids"],
            f"model.root_capacity_scenarios.{scenario_id}.required_full_component_ids",
        )
        axes = list_value(scenario["cartesian_axes"], f"model.root_capacity_scenarios.{scenario_id}.cartesian_axes")
        axis_options: list[list[list[str]]] = []
        for axis_position, axis in enumerate(axes):
            axis_location = f"model.root_capacity_scenarios.{scenario_id}.cartesian_axes[{axis_position}]"
            object_keys(axis, axis_location, {"id", "options"})
            string_value(axis["id"], f"{axis_location}.id")
            options: list[list[str]] = []
            for option_position, option in enumerate(list_value(axis["options"], f"{axis_location}.options")):
                options.append(unique_strings(option, f"{axis_location}.options[{option_position}]"))
            axis_options.append(options)
        scenario_coverage = set(unique_strings(scenario["coverage"], f"model.root_capacity_scenarios.{scenario_id}.coverage"))
        if not scenario_coverage <= ROOT_COVERAGE:
            fail(f"model.root_capacity_scenarios.{scenario_id}: unknown coverage label")
        coverage.update(scenario_coverage)
        seen_a = False
        seen_b = False
        for combination in itertools.product(*axis_options):
            selected = required + [component_id for option in combination for component_id in option]
            if len(selected) != len(set(selected)):
                fail(f"model.root_capacity_scenarios.{scenario_id}: duplicate component in Cartesian case")
            for component_id in selected:
                if component_id not in components:
                    fail(f"model.root_capacity_scenarios.{scenario_id}: unknown component {component_id}")
                if components[component_id]["root_id"] != root_id:
                    fail(f"model.root_capacity_scenarios.{scenario_id}: cross-root component {component_id}")
                seen_a = seen_a or component_id.endswith("_a")
                seen_b = seen_b or component_id.endswith("_b")
            case_sum = sum(components[item]["max_physical_bytes"] for item in selected)
            if case_sum > roots[root_id]["max_physical_bytes"]:
                fail(f"model.root_capacity_scenarios.{scenario_id}: Cartesian full case exceeds root maximum")
            cartesian_cases += 1
        if "live_scratch_ab" in scenario_coverage and not (seen_a and seen_b):
            fail(f"model.root_capacity_scenarios.{scenario_id}: A/B scratch coverage is incomplete")
        selected_names = " ".join(required + [item for axis in axis_options for option in axis for item in option])
        if "l1_semantic" in scenario_coverage and not ("journal_l1" in selected_names and "journal_semantic" in selected_names):
            fail(f"model.root_capacity_scenarios.{scenario_id}: L1+semantic co-residency is missing")
        if "admin_adoption" in scenario_coverage and not ("admin_live" in selected_names and "adoption_scratch" in selected_names):
            fail(f"model.root_capacity_scenarios.{scenario_id}: admin+adoption co-residency is missing")
        if "all_sources" in scenario_coverage:
            missing_sources = [
                source_id for source_id in model["policy_epoch"]["source_ids"]
                if source_id not in selected_names
            ]
            if missing_sources:
                fail(f"model.root_capacity_scenarios.{scenario_id}: admitted sources missing {missing_sources}")
    if coverage != ROOT_COVERAGE:
        fail(f"model.root_capacity_scenarios: missing root coverage {sorted(ROOT_COVERAGE - coverage)}")
    return components, roots, cartesian_cases


def validate_edges(
    model: dict[str, Any], tuple_sets: dict[str, Any], pair_sets: dict[str, Any]
) -> dict[str, Any]:
    edges = unique_index(model["edge_registry"], "model.edge_registry")
    for edge_id, edge in edges.items():
        object_keys(
            edge,
            f"model.edge_registry.{edge_id}",
            {"id", "version", "edge_type", "from_states", "to_states", "tuple_set_ids", "immutable_tuple", "receipt_requirements"},
            {"pair_set_ids"},
        )
        integer_value(edge["version"], f"model.edge_registry.{edge_id}.version", minimum=1)
        if edge["edge_type"] not in {"simple", "composite"}:
            fail(f"model.edge_registry.{edge_id}: unknown edge type")
        if edge["immutable_tuple"] is not True:
            fail(f"model.edge_registry.{edge_id}: every edge must preserve the immutable tuple")
        unique_strings(edge["from_states"], f"model.edge_registry.{edge_id}.from_states")
        unique_strings(edge["to_states"], f"model.edge_registry.{edge_id}.to_states")
        referenced_sets = unique_strings(edge["tuple_set_ids"], f"model.edge_registry.{edge_id}.tuple_set_ids")
        unknown_sets = set(referenced_sets) - tuple_sets.keys()
        if unknown_sets:
            fail(f"model.edge_registry.{edge_id}: unknown tuple sets {sorted(unknown_sets)}")
        referenced_pairs = unique_strings(
            edge.get("pair_set_ids", []),
            f"model.edge_registry.{edge_id}.pair_set_ids",
            nonempty=False,
        )
        unknown_pair_sets = set(referenced_pairs) - pair_sets.keys()
        if unknown_pair_sets:
            fail(f"model.edge_registry.{edge_id}: unknown pair sets {sorted(unknown_pair_sets)}")
        unique_strings(edge["receipt_requirements"], f"model.edge_registry.{edge_id}.receipt_requirements")
    compaction = edges.get("compaction_exchange")
    if not compaction or compaction["edge_type"] != "composite":
        fail("model.edge_registry.compaction_exchange: must be a declared composite edge")
    for edge_id in ("exact_split", "compaction_exchange"):
        if edges[edge_id].get("pair_set_ids") != ["all_live_scratch_pairs"]:
            fail(f"model.edge_registry.{edge_id}: must use exact live-to-scratch pairs")
    required_receipt = {
        "payload_accounting",
        "root_metadata_accounting",
        "ordered_before_after_units",
        "target_durable_receipt",
        "ordered_old_retirement_proofs",
        "root_before_after_digest",
        "predecessor_receipt_digest",
    }
    if not required_receipt <= set(compaction["receipt_requirements"]):
        fail("model.edge_registry.compaction_exchange: composite receipt is incomplete")
    for edge_id in ("attempt_reserve", "durable_abort", "forward_recovery"):
        if edges[edge_id]["tuple_set_ids"] != ["project_wal_live_tuples"]:
            fail(f"model.edge_registry.{edge_id}: pre-provider lifecycle may use live WAL tuples only")
    return edges


def validate_dag(nodes: list[Any], location: str) -> int:
    node_index: dict[str, dict[str, Any]] = {}
    for position, node in enumerate(nodes):
        node_location = f"{location}.nodes[{position}]"
        object_keys(node, node_location, {"id", "depends_on", "pre_state", "post_state", "atomic_group", "branch", "expected"})
        node_id = string_value(node["id"], f"{node_location}.id")
        if node_id in node_index:
            fail(f"{location}: duplicate node {node_id}")
        node_index[node_id] = node
        unique_strings(node["depends_on"], f"{node_location}.depends_on", nonempty=False)
        for field in ("pre_state", "post_state", "atomic_group", "branch"):
            string_value(node[field], f"{node_location}.{field}")
        expected = object_keys(node["expected"], f"{node_location}.expected", EXPECTED_KEYS)
        for field in EXPECTED_KEYS:
            string_value(expected[field], f"{node_location}.expected.{field}")
    for node_id, node in node_index.items():
        unknown = set(node["depends_on"]) - node_index.keys()
        if unknown:
            fail(f"{location}.{node_id}: unknown dependencies {sorted(unknown)}")
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(node_id: str) -> None:
        if node_id in visiting:
            fail(f"{location}: boundary path is cyclic at {node_id}")
        if node_id in visited:
            return
        visiting.add(node_id)
        for dependency in node_index[node_id]["depends_on"]:
            visit(dependency)
        visiting.remove(node_id)
        visited.add(node_id)

    for node_id in node_index:
        visit(node_id)
    return len(node_index)


def validate_selectors(
    model: dict[str, Any], edges: dict[str, Any], tuple_sets: dict[str, Any], pair_sets: dict[str, Any]
) -> tuple[dict[str, Any], int, int]:
    selectors = unique_index(model["selectors"], "model.selectors")
    if selectors.keys() != SELECTOR_IDS:
        fail(f"model.selectors: expected closed 13-selector set; missing={sorted(SELECTOR_IDS - selectors.keys())}")
    boundary_paths = 0
    boundary_nodes = 0
    for selector_id, selector in selectors.items():
        object_keys(
            selector,
            f"model.selectors.{selector_id}",
            {"id", "version", "command", "edge_ids", "tuple_set_ids", "boundary_paths"},
            {"pair_set_ids"},
        )
        integer_value(selector["version"], f"model.selectors.{selector_id}.version", minimum=1)
        command = string_value(selector["command"], f"model.selectors.{selector_id}.command")
        if command != EXPECTED_SELECTOR_COMMANDS[selector_id]:
            fail(f"model.selectors.{selector_id}: command differs from the closed exact invocation")
        edge_ids = unique_strings(selector["edge_ids"], f"model.selectors.{selector_id}.edge_ids")
        unknown_edges = set(edge_ids) - edges.keys()
        if unknown_edges:
            fail(f"model.selectors.{selector_id}: unknown edges {sorted(unknown_edges)}")
        set_ids = unique_strings(selector["tuple_set_ids"], f"model.selectors.{selector_id}.tuple_set_ids")
        unknown_sets = set(set_ids) - tuple_sets.keys()
        if unknown_sets:
            fail(f"model.selectors.{selector_id}: unknown tuple sets {sorted(unknown_sets)}")
        pair_set_ids = unique_strings(
            selector.get("pair_set_ids", []),
            f"model.selectors.{selector_id}.pair_set_ids",
            nonempty=False,
        )
        unknown_pair_sets = set(pair_set_ids) - pair_sets.keys()
        if unknown_pair_sets:
            fail(f"model.selectors.{selector_id}: unknown pair sets {sorted(unknown_pair_sets)}")
        path_ids: set[str] = set()
        for path_position, path in enumerate(list_value(selector["boundary_paths"], f"model.selectors.{selector_id}.boundary_paths")):
            path_location = f"model.selectors.{selector_id}.boundary_paths[{path_position}]"
            object_keys(path, path_location, {"id", "version", "nodes"})
            path_id = string_value(path["id"], f"{path_location}.id")
            if path_id in path_ids:
                fail(f"model.selectors.{selector_id}: duplicate boundary path {path_id}")
            path_ids.add(path_id)
            integer_value(path["version"], f"{path_location}.version", minimum=1)
            boundary_nodes += validate_dag(list_value(path["nodes"], f"{path_location}.nodes"), path_location)
            boundary_paths += 1
    return selectors, boundary_paths, boundary_nodes


def validate_retain_zero(model: dict[str, Any], components: dict[str, Any], edges: dict[str, Any]) -> None:
    contract = object_keys(
        model["retain_zero_contract"],
        "model.retain_zero_contract",
        {"payload_live_units_min", "empty_root_metadata_component_ids", "composite_receipt_sections"},
    )
    if integer_value(contract["payload_live_units_min"], "model.retain_zero_contract.payload_live_units_min") != 0:
        fail("model.retain_zero_contract: payload live-unit minimum must be zero")
    metadata_ids = unique_strings(
        contract["empty_root_metadata_component_ids"],
        "model.retain_zero_contract.empty_root_metadata_component_ids",
    )
    if len(metadata_ids) != 4 * len(model["policy_epoch"]["project_ids"]):
        fail("model.retain_zero_contract: manifest/checkpoint/queue A/B metadata are required for every project")
    roles: set[str] = set()
    roots: set[str] = set()
    for component_id in metadata_ids:
        component = components.get(component_id)
        if not component or component["component_type"] != "metadata":
            fail(f"model.retain_zero_contract: {component_id} is not declared root metadata")
        integer_value(component["max_physical_bytes"], f"model.root_components.{component_id}.max_physical_bytes", minimum=1)
        roles.add(component["metadata_role"])
        roots.add(component["root_id"])
    if roles != {
        "empty_root_manifest", "empty_root_checkpoint",
        "queue_metadata_generation_a", "queue_metadata_generation_b",
    } or roots != {f"{project_id}_storage_root" for project_id in model["policy_epoch"]["project_ids"]}:
        fail("model.retain_zero_contract: fixed project metadata coverage is incomplete")
    sections = set(unique_strings(contract["composite_receipt_sections"], "model.retain_zero_contract.composite_receipt_sections"))
    if sections != {"payload_accounting", "root_metadata_accounting"}:
        fail("model.retain_zero_contract: payload and root metadata accounting must be separate")
    if not sections <= set(edges["compaction_exchange"]["receipt_requirements"]):
        fail("model.retain_zero_contract: composite receipt does not cover both accounting sections")


def node_reaches(nodes: dict[str, Any], predecessor: str, successor: str) -> bool:
    pending = [successor]
    visited: set[str] = set()
    while pending:
        current = pending.pop()
        if current == predecessor:
            return True
        if current in visited:
            continue
        visited.add(current)
        pending.extend(nodes[current]["depends_on"])
    return False


def validate_l1_recovery(model: dict[str, Any], edges: dict[str, Any], selectors: dict[str, Any]) -> None:
    contract = object_keys(
        model["l1_materialized_recovery"],
        "model.l1_materialized_recovery",
        {"selector_id", "prepare_edge_id", "materialize_edge_id", "roll_forward_edge_id", "cleanup_edge_id", "prepared_intent_fields", "mismatch_outcomes", "exact_cleanup_requirements"},
    )
    expected_fields = {"resource_token_id", "exact_offset", "row_digest", "max_bytes"}
    if set(unique_strings(contract["prepared_intent_fields"], "model.l1_materialized_recovery.prepared_intent_fields")) != expected_fields:
        fail("model.l1_materialized_recovery: durable prepared intent fields are incomplete")
    if set(unique_strings(contract["mismatch_outcomes"], "model.l1_materialized_recovery.mismatch_outcomes")) != {
        "needs_repair",
        "exact_truncate_or_tombstone",
    }:
        fail("model.l1_materialized_recovery: mismatch outcomes are not closed")
    cleanup_requirements = {
        "capability_exact_offset",
        "tombstone_or_truncate",
        "file_fsync",
        "parent_directory_fsync",
        "materialized_retirement_receipt",
    }
    if set(unique_strings(contract["exact_cleanup_requirements"], "model.l1_materialized_recovery.exact_cleanup_requirements")) != cleanup_requirements:
        fail("model.l1_materialized_recovery: exact cleanup requirements are incomplete")
    for field in ("prepare_edge_id", "materialize_edge_id", "roll_forward_edge_id", "cleanup_edge_id"):
        if contract[field] not in edges:
            fail(f"model.l1_materialized_recovery: unknown edge {contract[field]}")
    if not expected_fields <= set(edges[contract["prepare_edge_id"]]["receipt_requirements"]):
        fail("model.l1_materialized_recovery: prepared intent is not durable before materialization")
    if not cleanup_requirements <= set(edges[contract["cleanup_edge_id"]]["receipt_requirements"]):
        fail("model.l1_materialized_recovery: cleanup edge lacks exact retirement proof")
    selector = selectors.get(contract["selector_id"])
    required_edges = {contract[field] for field in ("prepare_edge_id", "materialize_edge_id", "roll_forward_edge_id", "cleanup_edge_id")}
    if not selector or not required_edges <= set(selector["edge_ids"]):
        fail("model.l1_materialized_recovery: selector does not cover every recovery edge")
    all_nodes = {
        node["id"]: node
        for path in selector["boundary_paths"]
        for node in path["nodes"]
    }
    required_nodes = {
        "l1_prepared_intent_fsync",
        "l1_row_write",
        "l1_row_fsync",
        "l1_manifest_publish",
        "l1_mismatch_repair",
        "l1_exact_cleanup_durable",
        "l1_cleanup_release_receipt",
    }
    if not required_nodes <= all_nodes.keys():
        fail("model.l1_materialized_recovery: selector boundary coverage is incomplete")
    if not node_reaches(all_nodes, "l1_prepared_intent_fsync", "l1_row_write"):
        fail("model.l1_materialized_recovery: row write can precede durable prepared intent")
    if all_nodes["l1_mismatch_repair"]["post_state"] != "needs_repair":
        fail("model.l1_materialized_recovery: mismatch branch must fail visible")
    if all_nodes["l1_exact_cleanup_durable"]["post_state"] != "retirement_pending":
        fail("model.l1_materialized_recovery: cleanup credits capacity before durable retirement")
    if all_nodes["l1_exact_cleanup_durable"]["expected"]["crash_after"] != "materialized_retirement_durable":
        fail("model.l1_materialized_recovery: exact cleanup lacks materialized retirement state")
    if not node_reaches(all_nodes, "l1_exact_cleanup_durable", "l1_cleanup_release_receipt"):
        fail("model.l1_materialized_recovery: release receipt can precede durable retirement")
    if all_nodes["l1_cleanup_release_receipt"]["post_state"] != "released":
        fail("model.l1_materialized_recovery: cleanup lacks receipt-bound release")


def validate_model(model: dict[str, Any], schema: dict[str, Any]) -> dict[str, int]:
    validate_schema(schema)
    validate_schema_instance_or_fail(model, schema)
    object_keys(
        model,
        "model",
        {
            "authority",
            "version",
            "policy_epoch",
            "tuple_templates",
            "metadata_templates",
            "dimensions",
            "resource_kinds",
            "exact_scopes",
            "tuple_expansion_grammar",
            "tuples",
            "tuple_sets",
            "live_scratch_pairs",
            "live_scratch_pair_sets",
            "root_components",
            "roots",
            "root_capacity_scenarios",
            "edge_registry",
            "selectors",
            "retain_zero_contract",
            "l1_materialized_recovery",
        },
    )
    if model["authority"] != "docs/specs/GH704/resource_ledger_model.json":
        fail("model.authority: JSON model must name itself as the sole machine authority")
    integer_value(model["version"], "model.version", minimum=1)
    if model["dimensions"] != DIMENSIONS:
        fail("model.dimensions: expected the closed ordered six-dimensional set")
    if set(unique_strings(model["resource_kinds"], "model.resource_kinds")) != RESOURCE_KINDS:
        fail("model.resource_kinds: expected the closed 13-kind inventory")
    reject_symbolic_values(model)
    try:
        epoch_counts = validate_epoch_instance(model)
    except EpochModelError as exc:
        fail(f"model.policy_epoch: {exc}")
    tuples, tuple_sets = validate_tuple_model(model)
    pair_sets = unique_index(model["live_scratch_pair_sets"], "model.live_scratch_pair_sets")
    components, roots, cartesian_cases = validate_roots(model, tuples)
    edges = validate_edges(model, tuple_sets, pair_sets)
    selectors, boundary_paths, boundary_nodes = validate_selectors(model, edges, tuple_sets, pair_sets)
    validate_retain_zero(model, components, edges)
    validate_l1_recovery(model, edges, selectors)
    expanded_links = sum(
        len(tuple_sets[set_id]["tuple_ids"])
        for edge in edges.values()
        for set_id in edge["tuple_set_ids"]
    )
    return {
        "kinds": len(RESOURCE_KINDS),
        "tuples": len(tuples),
        "tuple_sets": len(tuple_sets),
        "root_components": len(components),
        "roots": len(roots),
        "cartesian_cases": cartesian_cases,
        "edges": len(edges),
        "expanded_edge_tuple_links": expanded_links,
        "selectors": len(selectors),
        "boundary_paths": boundary_paths,
        "boundaries": boundary_nodes,
        "fault_expectations": boundary_nodes * len(EXPECTED_KEYS),
        **epoch_counts,
    }


def self_test(model: dict[str, Any], schema: dict[str, Any]) -> int:
    cases: list[tuple[str, Callable[[dict[str, Any]], None]]] = [
        ("unknown_field", lambda value: value.__setitem__("unknown_field", 1)),
        ("unknown_kind", lambda value: value["tuples"][0].__setitem__("resource_kind", "unregistered_kind")),
        ("boolean_maximum", lambda value: value["tuples"][0]["maxima"].__setitem__("physical_bytes", True)),
        ("placeholder_scope", lambda value: value["tuples"][0].__setitem__("scope_id", "source_<id>")),
        ("pseudo_not_applicable", lambda value: value["tuples"][0].__setitem__("resource_kind", "N/A")),
        ("pseudo_tuple_not_applicable", lambda value: value["tuples"][0].__setitem__("quota_partition_id", "N/A")),
        ("unexpanded_partition", lambda value: value["tuples"][0].__setitem__("quota_partition_id", "generation_a|generation_b")),
        ("tuple_rewrite_edge", lambda value: value["edge_registry"][0].__setitem__("immutable_tuple", False)),
        ("missing_fault_state", lambda value: value["selectors"][0]["boundary_paths"][0]["nodes"][0]["expected"].pop("crash_before")),
        ("boundary_cycle", lambda value: value["selectors"][0]["boundary_paths"][0]["nodes"][0].__setitem__("depends_on", ["wal_final_exchange"])),
        ("cross_root_component", lambda value: value["root_capacity_scenarios"][1]["required_full_component_ids"].append("component_admin_live")),
        ("selector_gap", lambda value: value["selectors"].pop()),
        ("coverage_edge_gap", lambda value: next(item for item in value["selectors"] if item["id"] == "resource_kind_edge_coverage")["edge_ids"].pop()),
        ("coverage_tuple_set_rewrite", lambda value: next(item for item in value["selectors"] if item["id"] == "resource_kind_edge_coverage").__setitem__("tuple_set_ids", ["project_wal_live_tuples"])),
        ("retain_zero_metadata", lambda value: value["root_components"][24].__setitem__("max_physical_bytes", 0)),
        ("l1_intent_gap", lambda value: value["l1_materialized_recovery"]["prepared_intent_fields"].pop()),
        ("schema_pattern", lambda value: value["exact_scopes"].append("Bad Scope")),
        ("selector_command", lambda value: next(item for item in value["selectors"] if item["id"] == "wal_compaction_capacity_transfer").__setitem__("command", "true # wal_compaction_capacity_transfer")),
        ("scratch_attempt", lambda value: next(item for item in value["edge_registry"] if item["id"] == "attempt_reserve").__setitem__("tuple_set_ids", ["project_wal_tuples"])),
        ("cross_family_pair", lambda value: value["live_scratch_pairs"][0].__setitem__("scratch_tuple_id", "journal_scratch_alpha_a")),
        ("queue_metadata_gap", lambda value: value["retain_zero_contract"]["empty_root_metadata_component_ids"].pop()),
        ("wal_target_fsync_gap", lambda value: next(item for item in value["selectors"] if item["id"] == "wal_compaction_capacity_transfer")["boundary_paths"][0]["nodes"].pop(2)),
        ("l1_early_credit", lambda value: next(node for node in next(item for item in value["selectors"] if item["id"] == "canonical_journal_l1_entitlement_capacity_one")["boundary_paths"][0]["nodes"] if node["id"] == "l1_exact_cleanup_durable").__setitem__("post_state", "released")),
    ]
    for name, mutate in cases:
        candidate = copy.deepcopy(model)
        mutate(candidate)
        try:
            validate_model(candidate, schema)
        except ModelError:
            continue
        fail(f"self-test {name}: invalid mutation was accepted")
    positive = positive_expansion_model(model)
    positive_counts = validate_model(positive, schema)
    if positive_counts["epoch_sources"] != 3 or positive_counts["epoch_projects"] != 3:
        fail("self-test positive_epoch_materialization: expanded epoch was not fully validated")
    return len(cases)


def format_counts(counts: dict[str, int]) -> str:
    return " ".join(f"{key}={counts[key]}" for key in counts)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, default=MODEL_PATH)
    parser.add_argument("--schema", type=Path, default=SCHEMA_PATH)
    parser.add_argument("--self-test", action="store_true", help="prove representative reviewer mutations are rejected")
    args = parser.parse_args()
    try:
        model = load_resource_ledger_json(args.model)
        schema = load_resource_ledger_json(args.schema)
        counts = validate_model(model, schema)
        print(f"RESOURCE_LEDGER_MODEL_OK version={model['version']} {format_counts(counts)}")
        if args.self_test:
            case_count = self_test(model, schema)
            print(f"RESOURCE_LEDGER_MODEL_SELF_TEST_OK cases={case_count}")
    except ModelError as exc:
        print(f"RESOURCE_LEDGER_MODEL_ERROR {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

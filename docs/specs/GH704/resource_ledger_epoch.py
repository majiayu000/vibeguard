"""Deterministic policy-epoch materialization checks for GH-704 ResourceLedger."""

from __future__ import annotations

import copy
import hashlib
import json
from typing import Any


class EpochModelError(ValueError):
    """The sealed policy epoch does not materialize to the declared exact instance."""


EXPECTED_EDGE_TUPLE_SETS = {
    "reserve": ["all_exact_tuples"],
    "activate_live": ["all_exact_tuples"],
    "absence_release": ["all_exact_tuples"],
    "materialized_retirement": ["all_exact_tuples"],
    "transfer": ["reservation_bundle_tuples"],
    "exact_split": ["all_compaction_tuples"],
    "compaction_exchange": ["all_compaction_tuples"],
    "metadata_root_publish": ["derived_log_tuples"],
    "attempt_reserve": ["project_wal_live_tuples"],
    "durable_abort": ["project_wal_live_tuples"],
    "forward_recovery": ["project_wal_live_tuples"],
    "l1_append_prepare": ["l1_floor_tuples"],
    "l1_append_materialize": ["l1_floor_tuples"],
    "l1_append_roll_forward": ["l1_floor_tuples"],
    "l1_append_exact_cleanup": ["l1_floor_tuples"],
    "bounded_backpressure": ["all_exact_tuples"],
    "terminal_totality": ["reservation_bundle_tuples"],
    "expiry_gc": ["success_history_tuples"],
    "adopt_all_preflight": ["global_admin_tuples"],
    "adopt_all_publish": ["global_admin_tuples"],
    "adoption_retirement": ["global_admin_tuples"],
}


def canonical(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def resource_inventory_digest(epoch: dict[str, Any]) -> str:
    inventory = {
        "inventory_version": epoch["inventory_version"],
        "source_ids": sorted(epoch["source_ids"]),
        "project_ids": sorted(epoch["project_ids"]),
    }
    return hashlib.sha256(canonical(inventory).encode()).hexdigest()


def member_suffix(cardinality: str, member_id: str | None) -> str:
    if cardinality == "global_once":
        return ""
    if member_id is None:
        raise EpochModelError(f"{cardinality}: member is required")
    if cardinality == "per_project":
        if not member_id.startswith("project_"):
            raise EpochModelError(f"project id lacks project_ prefix: {member_id}")
        return member_id.removeprefix("project_")
    return member_id


def template_members(template: dict[str, Any], epoch: dict[str, Any]) -> list[str | None]:
    cardinality = template["cardinality"]
    if cardinality == "global_once":
        return [None]
    if cardinality == "per_source":
        return sorted(epoch["source_ids"])
    if cardinality == "per_project":
        return sorted(epoch["project_ids"])
    raise EpochModelError(f"unknown cardinality {cardinality}")


def bound_value(binding: str, member_id: str | None) -> str:
    if binding == "member_id":
        if member_id is None:
            raise EpochModelError("member_id binding on global template")
        return member_id
    if binding == "member_storage_root":
        if member_id is None:
            raise EpochModelError("member root binding on global template")
        return f"{member_id}_storage_root"
    if binding == "member_volume":
        if member_id is None:
            raise EpochModelError("member volume binding on global template")
        return f"{member_id}_volume"
    return binding


def expand_resource_tuples(model: dict[str, Any]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for template in model["tuple_templates"]:
        for member_id in template_members(template, model["policy_epoch"]):
            suffix = member_suffix(template["cardinality"], member_id)
            result.append({
                "id": f"{template['tuple_id_prefix']}{suffix}{template.get('tuple_id_suffix', '')}",
                "resource_kind": template["resource_kind"],
                "scope_id": bound_value(template["scope_binding"], member_id),
                "quota_partition_id": bound_value(template["quota_partition_binding"], member_id),
                "root_id": bound_value(template["root_binding"], member_id),
                "physical_domain": bound_value(template["physical_domain_binding"], member_id),
                "maxima": template["maxima"],
            })
    return result


def expand_metadata(model: dict[str, Any]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for template in model["metadata_templates"]:
        for member_id in template_members(template, model["policy_epoch"]):
            suffix = member_suffix(template["cardinality"], member_id)
            result.append({
                "id": f"{template['component_id_prefix']}{suffix}{template.get('component_id_suffix', '')}",
                "root_id": bound_value(template["root_binding"], member_id),
                "physical_domain": bound_value(template["physical_domain_binding"], member_id),
                "component_type": "metadata",
                "metadata_role": template["metadata_role"],
                "max_physical_bytes": template["max_physical_bytes"],
            })
    return result


def expected_tuple_set_memberships(tuples: dict[str, dict[str, Any]]) -> dict[str, set[str]]:
    kinds = lambda *values: {item["id"] for item in tuples.values() if item["resource_kind"] in values}
    memberships = {
        "all_exact_tuples": set(tuples),
        "project_wal_live_tuples": kinds("project_wal_live"),
        "project_wal_tuples": kinds("project_wal_live", "project_wal_scratch"),
        "canonical_journal_tuples": kinds("canonical_journal_live", "canonical_journal_scratch"),
        "l1_floor_tuples": {item["id"] for item in tuples.values() if item["quota_partition_id"] == "l1_floor"},
        "derived_log_tuples": kinds("derived_log_live", "derived_log_scratch"),
        "global_admin_tuples": kinds("global_admin"),
        "success_history_tuples": kinds("success_history"),
        "all_compaction_tuples": kinds(
            "project_wal_live", "project_wal_scratch", "derived_log_live",
            "derived_log_scratch", "canonical_journal_live", "canonical_journal_scratch",
        ),
    }
    bundle_kinds = {
        "registry_live_slot", "keyed_receipt_slot", "completed_index", "outbox",
        "quarantine_frozen_lag", "success_history",
    }
    memberships["reservation_bundle_tuples"] = kinds(*bundle_kinds) | {"admin_live", "derived_live"}
    return memberships


def materialize_roots(components: list[dict[str, Any]]) -> list[dict[str, Any]]:
    roots: dict[str, dict[str, Any]] = {}
    for component in components:
        root = roots.setdefault(component["root_id"], {
            "id": component["root_id"],
            "physical_domain": component["physical_domain"],
            "max_physical_bytes": 0,
            "component_ids": [],
        })
        root["max_physical_bytes"] += component["max_physical_bytes"]
        root["component_ids"].append(component["id"])
    return list(roots.values())


def materialize_scenarios(epoch: dict[str, Any]) -> list[dict[str, Any]]:
    global_required = [
        f"component_{prefix}{source_id}"
        for prefix in ("registry_", "receipt_", "completed_", "outbox_", "quarantine_", "history_")
        for source_id in sorted(epoch["source_ids"])
    ] + ["component_admin_live", "global_root_fixed_a", "global_root_fixed_b"]
    scenarios = [{
        "id": "global_epoch_sources_admin_adoption",
        "root_id": "global_control_root",
        "required_full_component_ids": global_required,
        "cartesian_axes": [{
            "id": "adoption_generation",
            "options": [["component_adoption_scratch_a"], ["component_adoption_scratch_b"]],
        }],
        "coverage": ["admin_adoption", "all_sources", "live_scratch_ab"],
    }]
    for project_id in sorted(epoch["project_ids"]):
        short = project_id.removeprefix("project_")
        scenarios.append({
            "id": f"project_{short}_live_scratch",
            "root_id": f"{project_id}_storage_root",
            "required_full_component_ids": [
                f"component_wal_live_{short}", f"component_journal_l1_{short}",
                f"component_journal_semantic_{short}", f"empty_root_manifest_{short}",
                f"empty_root_checkpoint_{short}", f"queue_metadata_{short}_a",
                f"queue_metadata_{short}_b",
            ],
            "cartesian_axes": [
                {"id": "wal_scratch_generation", "options": [
                    [f"component_wal_scratch_{short}_a"], [f"component_wal_scratch_{short}_b"],
                ]},
                {"id": "journal_scratch_generation", "options": [
                    [f"component_journal_scratch_{short}_a"], [f"component_journal_scratch_{short}_b"],
                ]},
            ],
            "coverage": ["live_scratch_ab", "l1_semantic"],
        })
    scenarios.append({
        "id": "allocator_live_scratch",
        "root_id": "allocator_root",
        "required_full_component_ids": [
            "component_derived_live", "allocator_root_fixed_a", "allocator_root_fixed_b",
        ],
        "cartesian_axes": [{
            "id": "derived_scratch_generation",
            "options": [["component_derived_scratch_a"], ["component_derived_scratch_b"]],
        }],
        "coverage": ["live_scratch_ab"],
    })
    return scenarios


def materialize_epoch(model: dict[str, Any], source_ids: list[str], project_ids: list[str]) -> dict[str, Any]:
    candidate = copy.deepcopy(model)
    epoch = candidate["policy_epoch"]
    epoch["source_ids"] = sorted(source_ids)
    epoch["project_ids"] = sorted(project_ids)
    epoch["inventory_digest"] = resource_inventory_digest(epoch)
    candidate["exact_scopes"] = ["global", *epoch["source_ids"], *epoch["project_ids"]]
    candidate["tuples"] = expand_resource_tuples(candidate)
    tuples = exact_index(candidate["tuples"], "materialized tuples")
    memberships = expected_tuple_set_memberships(tuples)
    tuple_order = list(tuples)
    candidate["tuple_sets"] = [
        {"id": set_id, "tuple_ids": [tuple_id for tuple_id in tuple_order if tuple_id in memberships[set_id]]}
        for set_id in memberships
    ]
    old_pair_ids = {
        (item["live_tuple_id"], item["scratch_tuple_id"]): item["id"]
        for item in candidate["live_scratch_pairs"]
    }
    allowed_families = {
        "project_wal_live": "project_wal_scratch",
        "derived_log_live": "derived_log_scratch",
        "canonical_journal_live": "canonical_journal_scratch",
    }
    pairs = []
    for live in tuples.values():
        for scratch in tuples.values():
            relation = (live["id"], scratch["id"])
            if allowed_families.get(live["resource_kind"]) != scratch["resource_kind"]:
                continue
            if any(live[field] != scratch[field] for field in ("root_id", "physical_domain", "scope_id")):
                continue
            pairs.append({
                "id": old_pair_ids.get(relation, f"pair_{live['id']}_to_{scratch['id']}"),
                "live_tuple_id": live["id"],
                "scratch_tuple_id": scratch["id"],
            })
    candidate["live_scratch_pairs"] = pairs
    candidate["live_scratch_pair_sets"] = [{
        "id": "all_live_scratch_pairs", "pair_ids": [item["id"] for item in pairs],
    }]
    components = [{
        "id": f"component_{item['id']}", "root_id": item["root_id"],
        "physical_domain": item["physical_domain"], "component_type": "tuple",
        "tuple_id": item["id"], "max_physical_bytes": item["maxima"]["physical_bytes"],
    } for item in candidate["tuples"]] + expand_metadata(candidate)
    candidate["root_components"] = components
    candidate["roots"] = materialize_roots(components)
    candidate["root_capacity_scenarios"] = materialize_scenarios(epoch)
    candidate["retain_zero_contract"]["empty_root_metadata_component_ids"] = [
        component["id"] for component in components
        if component.get("metadata_role") in {
            "empty_root_manifest", "empty_root_checkpoint",
            "queue_metadata_generation_a", "queue_metadata_generation_b",
        }
    ]
    return candidate


def exact_index(items: list[dict[str, Any]], location: str) -> dict[str, dict[str, Any]]:
    result = {item["id"]: item for item in items}
    if len(result) != len(items):
        raise EpochModelError(f"{location}: duplicate ids")
    return result


def require_exact(actual: list[dict[str, Any]], expected: list[dict[str, Any]], location: str) -> None:
    if exact_index(actual, location) != exact_index(expected, f"expected {location}"):
        raise EpochModelError(f"{location}: materialized instance differs from templates")


def validate_pair_relations(model: dict[str, Any], tuples: dict[str, dict[str, Any]]) -> None:
    allowed_families = {
        "project_wal_live": "project_wal_scratch",
        "derived_log_live": "derived_log_scratch",
        "canonical_journal_live": "canonical_journal_scratch",
    }
    exact_index(model["live_scratch_pairs"], "live_scratch_pairs")
    seen: set[tuple[str, str]] = set()
    for pair in model["live_scratch_pairs"]:
        live = tuples.get(pair["live_tuple_id"])
        scratch = tuples.get(pair["scratch_tuple_id"])
        if live is None or scratch is None:
            raise EpochModelError(f"pair {pair['id']}: unknown tuple")
        if allowed_families.get(live["resource_kind"]) != scratch["resource_kind"]:
            raise EpochModelError(f"pair {pair['id']}: resource family mismatch")
        for field in ("root_id", "physical_domain", "scope_id"):
            if live[field] != scratch[field]:
                raise EpochModelError(f"pair {pair['id']}: {field} mismatch")
        relation = (live["id"], scratch["id"])
        if relation in seen:
            raise EpochModelError(f"pair {pair['id']}: duplicate relation")
        seen.add(relation)
    expected = {
        (live["id"], scratch["id"])
        for live in tuples.values()
        for scratch in tuples.values()
        if allowed_families.get(live["resource_kind"]) == scratch["resource_kind"]
        and all(live[field] == scratch[field] for field in ("root_id", "physical_domain", "scope_id"))
    }
    if seen != expected:
        raise EpochModelError("live_scratch_pairs: relations are not finite-complete")
    pair_ids = {item["id"] for item in model["live_scratch_pairs"]}
    pair_sets = exact_index(model["live_scratch_pair_sets"], "live_scratch_pair_sets")
    if set(pair_sets.get("all_live_scratch_pairs", {}).get("pair_ids", [])) != pair_ids:
        raise EpochModelError("all_live_scratch_pairs: must enumerate every pair")


def validate_named_tuple_sets(model: dict[str, Any], tuples: dict[str, dict[str, Any]]) -> None:
    sets = exact_index(model["tuple_sets"], "tuple_sets")
    memberships = {set_id: set(item["tuple_ids"]) for set_id, item in sets.items()}
    if memberships != expected_tuple_set_memberships(tuples):
        raise EpochModelError("tuple_sets: named membership differs from epoch expansion")


def validate_resource_kind_coverage(model: dict[str, Any], tuples: dict[str, dict[str, Any]]) -> None:
    selectors = exact_index(model["selectors"], "selectors")
    selector = selectors.get("resource_kind_edge_coverage")
    edges = exact_index(model["edge_registry"], "edge_registry")
    tuple_sets = exact_index(model["tuple_sets"], "tuple_sets")
    if selector is None or set(selector["edge_ids"]) != set(edges):
        raise EpochModelError("resource_kind_edge_coverage: must enumerate every edge exactly")
    actual_edge_sets = {edge_id: edge["tuple_set_ids"] for edge_id, edge in edges.items()}
    if actual_edge_sets != EXPECTED_EDGE_TUPLE_SETS:
        raise EpochModelError("resource_kind_edge_coverage: per-edge tuple-set relation differs from the closed contract")
    if selector["tuple_set_ids"] != ["all_exact_tuples"]:
        raise EpochModelError("resource_kind_edge_coverage: must select the complete exact tuple inventory")
    covered_tuple_ids = {
        tuple_id
        for edge in edges.values()
        for set_id in edge["tuple_set_ids"]
        for tuple_id in tuple_sets[set_id]["tuple_ids"]
    }
    if covered_tuple_ids != set(tuples):
        raise EpochModelError("resource_kind_edge_coverage: edge registry leaves exact tuples uncovered")
    covered_kinds = {tuples[tuple_id]["resource_kind"] for tuple_id in covered_tuple_ids}
    if covered_kinds != set(model["resource_kinds"]):
        raise EpochModelError("resource_kind_edge_coverage: edge registry leaves resource kinds uncovered")


def reaches(nodes: dict[str, dict[str, Any]], predecessor: str, successor: str) -> bool:
    pending = [successor]
    seen: set[str] = set()
    while pending:
        current = pending.pop()
        if current == predecessor:
            return True
        if current in seen:
            continue
        seen.add(current)
        if current not in nodes:
            raise EpochModelError(f"boundary dependency references missing node {current}")
        pending.extend(nodes[current]["depends_on"])
    return False


def validate_boundary_contracts(model: dict[str, Any]) -> None:
    selectors = exact_index(model["selectors"], "selectors")
    compaction = selectors["wal_compaction_capacity_transfer"]
    compaction_nodes = exact_index(compaction["boundary_paths"][0]["nodes"], "wal compaction nodes")
    compaction_order = [
        "wal_scratch_reserve", "wal_target_write", "wal_target_fsync",
        "wal_authority_publish", "wal_old_tombstone", "wal_old_directory_fsync",
        "wal_final_exchange",
    ]
    if any(not reaches(compaction_nodes, earlier, later) for earlier, later in zip(compaction_order, compaction_order[1:])):
        raise EpochModelError("WAL compaction omits target or ordered retirement durability")
    terminal = selectors["project_wal_pre_provider_terminal_closure"]
    paths = {path["id"]: exact_index(path["nodes"], path["id"]) for path in terminal["boundary_paths"]}
    required_paths = {
        "wal_absence_release_path": ["absence_attempt_reserve", "absence_proof_publish", "absence_release_receipt"],
        "wal_durable_abort_path": ["abort_attempt_reserve", "abort_prepared_fsync", "abort_receipt_fsync", "abort_retirement_publish", "abort_release_receipt"],
        "wal_forward_recovery_path": ["forward_attempt_reserve", "forward_prepared_fsync", "forward_journal_write", "forward_journal_fsync", "forward_journaled_fsync", "forward_done_receipt"],
    }
    if set(paths) != set(required_paths):
        raise EpochModelError("WAL terminal branches are not explicit and closed")
    for path_id, order in required_paths.items():
        if set(paths[path_id]) != set(order) or any(not reaches(paths[path_id], earlier, later) for earlier, later in zip(order, order[1:])):
            raise EpochModelError(f"{path_id}: fault boundaries are incomplete or unordered")


def validate_epoch_instance(model: dict[str, Any]) -> dict[str, int]:
    epoch = model["policy_epoch"]
    if epoch["inventory_digest"] != resource_inventory_digest(epoch):
        raise EpochModelError("policy_epoch: inventory digest mismatch")
    expected_scopes = {"global", *epoch["source_ids"], *epoch["project_ids"]}
    if set(model["exact_scopes"]) != expected_scopes:
        raise EpochModelError("exact_scopes: must equal sealed epoch membership plus global")
    expanded = expand_resource_tuples(model)
    require_exact(model["tuples"], expanded, "tuples")
    tuples = exact_index(expanded, "expanded tuples")
    expected_components = [
        {
            "id": f"component_{item['id']}", "root_id": item["root_id"],
            "physical_domain": item["physical_domain"], "component_type": "tuple",
            "tuple_id": item["id"], "max_physical_bytes": item["maxima"]["physical_bytes"],
        }
        for item in expanded
    ] + expand_metadata(model)
    require_exact(model["root_components"], expected_components, "root_components")
    validate_pair_relations(model, tuples)
    validate_named_tuple_sets(model, tuples)
    validate_resource_kind_coverage(model, tuples)
    validate_boundary_contracts(model)
    component_index = exact_index(expected_components, "expanded components")
    expected_roots: dict[str, dict[str, Any]] = {}
    for component in expected_components:
        root = expected_roots.setdefault(component["root_id"], {
            "id": component["root_id"], "physical_domain": component["physical_domain"],
            "max_physical_bytes": 0, "component_ids": [],
        })
        if root["physical_domain"] != component["physical_domain"]:
            raise EpochModelError(f"root {root['id']}: physical domain mismatch")
        root["max_physical_bytes"] += component["max_physical_bytes"]
        root["component_ids"].append(component["id"])
    actual_roots = exact_index(model["roots"], "roots")
    for root in expected_roots.values():
        actual = actual_roots.get(root["id"])
        if actual is None or actual["physical_domain"] != root["physical_domain"] or actual["max_physical_bytes"] != root["max_physical_bytes"] or set(actual["component_ids"]) != set(root["component_ids"]):
            raise EpochModelError(f"root {root['id']}: not the exact epoch component sum")
    if set(actual_roots) != set(expected_roots):
        raise EpochModelError("roots: extra or missing epoch root")
    require_exact(
        model["root_capacity_scenarios"],
        materialize_scenarios(epoch),
        "root_capacity_scenarios",
    )
    return {
        "epoch_sources": len(epoch["source_ids"]),
        "epoch_projects": len(epoch["project_ids"]),
        "templates": len(model["tuple_templates"]),
        "metadata_templates": len(model["metadata_templates"]),
        "pairs": len(model["live_scratch_pairs"]),
        "components": len(component_index),
    }


def positive_expansion_model(model: dict[str, Any]) -> dict[str, Any]:
    candidate = materialize_epoch(
        model,
        [*model["policy_epoch"]["source_ids"], "source_gamma"],
        [*model["policy_epoch"]["project_ids"], "project_gamma"],
    )
    source_tuples = [item for item in candidate["tuples"] if item["id"].endswith("source_gamma")]
    project_tuples = [item for item in candidate["tuples"] if item["scope_id"] == "project_gamma"]
    project_components = [
        item for item in candidate["root_components"]
        if item["root_id"] == "project_gamma_storage_root"
    ]
    project_pairs = [
        item for item in candidate["live_scratch_pairs"]
        if "_gamma" in item["live_tuple_id"]
    ]
    if (len(source_tuples), len(project_tuples), len(project_components), len(project_pairs)) != (6, 7, 11, 6):
        raise EpochModelError("positive epoch expansion did not materialize complete tuple/component/pair inventory")
    if not any(item["id"] == "project_gamma_storage_root" for item in candidate["roots"]):
        raise EpochModelError("positive epoch expansion did not materialize the new project root")
    return candidate

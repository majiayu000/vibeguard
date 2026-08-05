#!/usr/bin/env python3
"""Strict validator and negative self-tests for the GH-703 operation matrix."""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
from typing import Any


MATRIX_PATH = Path(__file__).with_name("operation_matrix.json")
TOP_KEYS = {
    "schema_version",
    "contract_id",
    "normative",
    "commit_primitive",
    "chains",
    "status_reasons",
    "operations",
}
PRIMITIVE_KEYS = {"id", "linux", "macos", "forbidden"}
CHAIN_KEYS = {
    "record_path",
    "commit_marker_path",
    "commit_marker_required",
    "commit_unit",
}
STATUS_KEYS = {"publishable", "terminal_no_publish", "publishable_precedence"}
OPERATION_KEYS = {
    "operation_id",
    "allowed_chains",
    "required_chain_order",
    "forbidden_chains",
    "commit_marker_policy",
    "publishability",
    "reserve_capacity",
    "authority",
    "recovery_terminal",
}
RESERVE_KEYS = {"class", "required_capacity", "may_consume_terminal_cleanup_reserve"}
AUTHORITY_KEYS = {"type", "required_chain", "pointer_record_type"}
EXPECTED_CHAINS = {
    "source_generation",
    "authority_journal",
    "generation_claim",
    "generation_binding",
    "ownership_receipt",
    "lifecycle_terminal",
    "current_pointer",
    "audit_checkpoint",
}
EXPECTED_OPERATIONS = {
    "source_generation_bootstrap",
    "authority_journal_append",
    "current_generation_publish",
    "disable_no_current",
    "clean_no_current",
    "audit_checkpoint_publish",
    "integrity_failure",
}
RECOVERY_TERMINALS = {
    "nonzero_block_activation",
    "seal_epoch_and_fail_visible",
    "nonzero_stale_keep_prior_pointer",
    "nonzero_retry_exact_remaining_terminal_steps",
    "nonzero_stop_publish_and_retention",
}


class ContractError(ValueError):
    """The operation matrix violates its closed contract."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ContractError(message)


def require_exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    actual = set(value)
    require(actual == expected, f"{label}: keys differ: missing={sorted(expected - actual)}, unknown={sorted(actual - expected)}")


def require_unique(values: list[Any], label: str) -> None:
    require(len(values) == len(set(values)), f"{label}: duplicate value")


def operation_map(matrix: dict[str, Any]) -> dict[str, dict[str, Any]]:
    operations = matrix["operations"]
    require(isinstance(operations, list), "operations: expected list")
    ids = [operation.get("operation_id") for operation in operations]
    require_unique(ids, "operations.operation_id")
    require(set(ids) == EXPECTED_OPERATIONS, f"operations: omission/unknown IDs: {sorted(set(ids) ^ EXPECTED_OPERATIONS)}")
    return {operation["operation_id"]: operation for operation in operations}


def validate(matrix: dict[str, Any]) -> None:
    require_exact_keys(matrix, TOP_KEYS, "matrix")
    require(matrix["schema_version"] == 1, "schema_version: expected 1")
    require(matrix["contract_id"] == "gh703_operation_matrix_v1", "contract_id: unexpected")
    require(matrix["normative"] is True, "normative: expected true")

    primitive = matrix["commit_primitive"]
    require_exact_keys(primitive, PRIMITIVE_KEYS, "commit_primitive")
    require(primitive["id"] == "exclusive_no_replace_rename", "commit_primitive.id: unexpected")
    require(primitive["linux"] == "renameat2(RENAME_NOREPLACE)", "commit_primitive.linux: unexpected")
    require(primitive["macos"] == "renameatx_np(RENAME_EXCL)", "commit_primitive.macos: unexpected")
    require_unique(primitive["forbidden"], "commit_primitive.forbidden")
    require("hard_link" in primitive["forbidden"], "commit_primitive: hard-link publication must be forbidden")

    chains = matrix["chains"]
    require(isinstance(chains, dict), "chains: expected object")
    require(set(chains) == EXPECTED_CHAINS, f"chains: omission/unknown IDs: {sorted(set(chains) ^ EXPECTED_CHAINS)}")
    all_paths: list[str] = []
    for chain_id, chain in chains.items():
        require_exact_keys(chain, CHAIN_KEYS, f"chains.{chain_id}")
        record_path = chain["record_path"]
        marker_path = chain["commit_marker_path"]
        require(isinstance(record_path, str) and record_path, f"chains.{chain_id}.record_path: expected non-empty string")
        all_paths.append(record_path)
        if chain["commit_marker_required"]:
            require(chain["commit_unit"] == "record_marker_pair", f"chains.{chain_id}: marker chain must use record_marker_pair")
            require(isinstance(marker_path, str) and marker_path, f"chains.{chain_id}: marker path required")
            require("/records/" in record_path and "/commits/" in marker_path, f"chains.{chain_id}: record/marker cross-pair")
            require(record_path.split("/records/", 1)[0] == marker_path.split("/commits/", 1)[0], f"chains.{chain_id}: record/marker namespace cross-pair")
            all_paths.append(marker_path)
        else:
            require(marker_path is None, f"chains.{chain_id}: marker path forbidden")
            require(chain["commit_unit"] in {"record", "atomic_directory"}, f"chains.{chain_id}: invalid marker-free commit unit")
    require_unique(all_paths, "chains paths")

    reasons = matrix["status_reasons"]
    require_exact_keys(reasons, STATUS_KEYS, "status_reasons")
    for key, values in reasons.items():
        require(isinstance(values, list), f"status_reasons.{key}: expected list")
        require_unique(values, f"status_reasons.{key}")
    publishable = set(reasons["publishable"])
    terminal = set(reasons["terminal_no_publish"])
    require(not publishable & terminal, "status_reasons: publishable/terminal overlap")
    require("ledger_corrupt" in terminal and "ledger_corrupt" not in publishable, "ledger_corrupt must be terminal no-publish")
    require(set(reasons["publishable_precedence"]) <= publishable, "publishable_precedence: unknown/nonpublishable reason")
    require("ledger_corrupt" not in reasons["publishable_precedence"], "ledger_corrupt must not participate in publishable precedence")

    operations = operation_map(matrix)
    for operation_id, operation in operations.items():
        require_exact_keys(operation, OPERATION_KEYS, f"operations.{operation_id}")
        for key in ("allowed_chains", "required_chain_order", "forbidden_chains"):
            values = operation[key]
            require(isinstance(values, list), f"operations.{operation_id}.{key}: expected list")
            require_unique(values, f"operations.{operation_id}.{key}")
            require(set(values) <= EXPECTED_CHAINS, f"operations.{operation_id}.{key}: unknown chain")
        allowed = set(operation["allowed_chains"])
        required = set(operation["required_chain_order"])
        forbidden = set(operation["forbidden_chains"])
        require(required == allowed, f"operations.{operation_id}: required chain omission/extra")
        require(not allowed & forbidden, f"operations.{operation_id}: allowed/forbidden chain overlap")
        require(allowed | forbidden == EXPECTED_CHAINS, f"operations.{operation_id}: allowed/forbidden chain omission")
        require(operation["commit_marker_policy"] in {"chain_registry", "no_commit"}, f"operations.{operation_id}: invalid commit marker policy")
        if allowed:
            require(operation["commit_marker_policy"] == "chain_registry", f"operations.{operation_id}: chain commit must use registry")
        else:
            require(operation["commit_marker_policy"] == "no_commit", f"operations.{operation_id}: empty operation must not commit")
        reserve = operation["reserve_capacity"]
        authority = operation["authority"]
        require_exact_keys(reserve, RESERVE_KEYS, f"operations.{operation_id}.reserve_capacity")
        require_exact_keys(authority, AUTHORITY_KEYS, f"operations.{operation_id}.authority")
        require_unique(reserve["required_capacity"], f"operations.{operation_id}.reserve_capacity.required_capacity")
        require(authority["required_chain"] is None or authority["required_chain"] in allowed, f"operations.{operation_id}: authority chain not allowed")
        require(authority["pointer_record_type"] in {None, "current_generation", "no_current"}, f"operations.{operation_id}: unknown pointer record type")
        require(operation["recovery_terminal"] in RECOVERY_TERMINALS, f"operations.{operation_id}: unknown recovery terminal")

    current = operations["current_generation_publish"]
    require(current["required_chain_order"] == ["generation_claim", "generation_binding", "ownership_receipt", "current_pointer"], "current_generation_publish: exact chain order required")
    require("lifecycle_terminal" in current["forbidden_chains"], "current_generation_publish: lifecycle terminal must be forbidden")
    require(current["authority"] == {"type": "ownership_receipt", "required_chain": "ownership_receipt", "pointer_record_type": "current_generation"}, "current_generation_publish: authority cross-pair")
    require(current["reserve_capacity"]["may_consume_terminal_cleanup_reserve"] is False, "current_generation_publish: terminal cleanup reserve is forbidden")

    for operation_id in ("disable_no_current", "clean_no_current"):
        operation = operations[operation_id]
        require(operation["required_chain_order"] == ["lifecycle_terminal", "current_pointer"], f"{operation_id}: exact terminal chain order required")
        require(operation["authority"] == {"type": "lifecycle_terminal", "required_chain": "lifecycle_terminal", "pointer_record_type": "no_current"}, f"{operation_id}: authority cross-pair")
        require(operation["reserve_capacity"]["may_consume_terminal_cleanup_reserve"] is True, f"{operation_id}: cleanup reserve required")

    journal_capacity = operations["authority_journal_append"]["reserve_capacity"]["required_capacity"]
    require(journal_capacity == ["open_slot_terminal_record", "next_heartbeat_record"], "authority_journal_append: exact open-slot/heartbeat reserve required")
    require(chains["current_pointer"]["commit_marker_required"] is True, "current_pointer: marker required")


def expect_rejected(base: dict[str, Any], name: str, mutate: Any) -> None:
    candidate = copy.deepcopy(base)
    mutate(candidate)
    try:
        validate(candidate)
    except ContractError:
        print(f"PASS negative/{name}")
        return
    raise ContractError(f"negative/{name}: invalid matrix was accepted")


def run_self_tests(matrix: dict[str, Any]) -> None:
    validate(matrix)
    expect_rejected(matrix, "duplicate_operation", lambda value: value["operations"].append(copy.deepcopy(value["operations"][0])))
    expect_rejected(matrix, "unknown_chain", lambda value: value["operations"][2]["allowed_chains"].append("unknown_chain"))
    expect_rejected(matrix, "required_chain_omission", lambda value: value["operations"][2]["required_chain_order"].remove("ownership_receipt"))
    expect_rejected(matrix, "chain_partition_omission", lambda value: value["operations"][2]["forbidden_chains"].remove("source_generation"))
    expect_rejected(matrix, "record_marker_cross_pair", lambda value: value["chains"]["current_pointer"].__setitem__("commit_marker_path", value["chains"]["ownership_receipt"]["commit_marker_path"]))
    expect_rejected(matrix, "authority_cross_pair", lambda value: value["operations"][3]["authority"].update({"type": "ownership_receipt", "required_chain": "ownership_receipt", "pointer_record_type": "current_generation"}))
    expect_rejected(matrix, "ledger_corrupt_publishable", lambda value: value["status_reasons"]["publishable"].append("ledger_corrupt"))
    expect_rejected(matrix, "pointer_marker_omission", lambda value: value["chains"]["current_pointer"].update({"commit_marker_path": None, "commit_marker_required": False, "commit_unit": "record"}))
    expect_rejected(matrix, "normal_publish_terminal_chain", lambda value: value["operations"][2]["allowed_chains"].append("lifecycle_terminal"))
    expect_rejected(matrix, "journal_reserve_omission", lambda value: value["operations"][1]["reserve_capacity"]["required_capacity"].remove("next_heartbeat_record"))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("matrix", nargs="?", type=Path, default=MATRIX_PATH)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    matrix = json.loads(args.matrix.read_text(encoding="utf-8"))
    if not isinstance(matrix, dict):
        raise ContractError("matrix root: expected object")
    if args.self_test:
        run_self_tests(matrix)
    else:
        validate(matrix)
    print(f"PASS {args.matrix}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

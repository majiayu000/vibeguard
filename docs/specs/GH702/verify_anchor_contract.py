#!/usr/bin/env python3
"""Executable semantic, golden, and mutation contract for the GH-702 draft."""

from __future__ import annotations

import base64
import copy
import hashlib
import json
import re
from datetime import datetime
from pathlib import Path


ROOT = Path(__file__).resolve().parent
VECTORS = ROOT / "anchor_contract_vectors.json"
MONOTONIC = ROOT / "monotonic-anchor-contract.md"
ATOMIC = ROOT / "atomic-launch-machine-contract.md"
ANNEX = ROOT / "anchor-identity-verification-contract.md"
TECH = ROOT / "tech.md"
PRODUCT = ROOT / "product.md"
S = "string"
I = "integer"
SIGNER_KEYS = {"signer-a": b"GH702 fixture signer A", "signer-b": b"GH702 fixture signer B"}
MODE_PAIRS = {
    "anchor_block_v1": "external_launch_floor_anchor_v1",
    "authenticated_no_block_v1": "permanent_backend_free_no_block_v1",
}
OPERATION_SCHEMAS = {
    "advance_policy_evaluation": {
        "schema_version": I, "variant": S, "from_policy_generation": I,
        "target_policy_generation": I, "committed_policy_digest": S,
        "evaluation_policy_digest": S,
    },
    "advance_installation_generation": {
        "schema_version": I, "variant": S, "installation_scope_id": S,
        "from_installation_generation": I, "target_installation_generation": I,
        "committed_installation_digest": S,
    },
    "advance_time_high_water": {
        "schema_version": I, "variant": S, "installation_scope_id": S,
        "clock_epoch": I, "from_sequence": I, "target_sequence": I,
        "from_high_water": I, "target_high_water": I,
    },
    "reconcile_clock_epoch": {
        "schema_version": I, "variant": S, "installation_scope_id": S,
        "from_clock_epoch": I, "target_clock_epoch": I,
        "reconciliation_evidence_digest": S,
    },
}
BACKEND_SCHEMA = {
    "backend_kind": S, "backend_instance_id": S, "device_key_digest": S,
    "protocol_version": I,
}
SIGNER_SCHEMA = {"signer_key_id": S, "signature_algorithm": S, "verification_key_digest": S}
PROFILE_SCHEMA = {
    "schema_version": I, "launch_authority_profile_id": S,
    "launch_authority_backend_identity": BACKEND_SCHEMA,
    "signature_quorum": I, "trusted_signers": [SIGNER_SCHEMA],
    "max_attestation_validity_ms": I, "resume_token_min_entropy_bits": I,
    "max_suspended_lifetime_ms": I, "freshness_protocol": S, "resume_protocol": S,
}
TEMPLATE_SCHEMA = {
    "schema_version": I, "executable_binary_digest": S, "argv_digest": S,
    "environment_digest": S, "working_directory_digest": S,
    "principal_identity_digest": S, "sandbox_profile_digest": S,
    "ipc_profile_digest": S, "loaded_image_policy_digest": S,
    "code_signing_policy_digest": S, "injection_controls_policy_digest": S,
    "measurement_policy_digest": S,
}
BINARY_SCHEMA = {"version": S, "binary_digest": S}
CORE_TEMPLATE_SCHEMA = {
    "schema_version": I, "entrypoint_id": S, "argv_digest": S,
    "environment_digest": S, "working_directory_digest": S,
    "principal_identity_digest": S, "sandbox_profile_digest": S, "ipc_profile_digest": S,
}
POLICY_SCHEMA = {
    "schema_version": I, "launch_authority_profile_digest": S, "platform_id": S,
    "platform_profile_family_id": S, "global_platform_registry_entry_digest": S,
    "approved_core_binary": BINARY_SCHEMA, "approved_host_adapter_binary": BINARY_SCHEMA,
    "approved_adapter_process_template_digest": S,
    "approved_core_process_template": CORE_TEMPLATE_SCHEMA,
    "consumed_transaction_tombstone_retention_digest": S, "enforcement_stage": S,
}
PEER_SCHEMA = {
    "launch_session_id": S, "challenge_nonce": S, "launch_transaction_id": S,
    "authenticated_peer_process_id": S, "process_start_identity": S,
    "authenticated_channel_binding_digest": S, "peer_evidence_digest": S,
}
REQUEST_SCHEMA = {
    "launch_session_id": S, "challenge_nonce": S, "launch_transaction_id": S,
    "authenticated_channel_binding_digest": S,
}
ATTESTATION_BODY_SCHEMA = {
    "schema_version": I, "launch_session_id": S, "challenge_nonce": S,
    "launch_transaction_id": S, "launch_request_identity_digest": S,
    "peer_evidence_digest": S, "launch_authority_profile_digest": S,
    "launch_policy_digest": S, "launch_authority_backend_identity": BACKEND_SCHEMA,
    "authenticated_channel_binding_digest": S, "authenticated_peer_process_id": S,
    "process_start_identity": S, "executable_object_identity": S,
    "executable_binary_digest": S, "loaded_image_set_digest": S,
    "code_signing_identity_digest": S, "effective_argv_digest": S,
    "effective_environment_digest": S, "working_directory_object_digest": S,
    "effective_principal_digest": S, "sandbox_profile_digest": S,
    "ipc_profile_digest": S, "injection_controls_digest": S,
    "measurement_policy_digest": S, "measured_at": S, "expires_at": S,
}
ATTESTATION_SIGNATURE_SCHEMA = {"signer_key_id": S, "signature_algorithm": S, "signature": S}
ATTESTATION_SCHEMA = {
    "digest_domain": S, "schema_version": I, "body": ATTESTATION_BODY_SCHEMA,
    "attestation_digest": S, "signatures": [ATTESTATION_SIGNATURE_SCHEMA],
}
WINDOWS_SCHEMA = {"arguments": [S], "command_line_base64url": S, "command_line_sha256": S}
TOMBSTONE_SCHEMA = {
    "reuse_guard_generation": I, "previous_state_digest": S,
    "durable_consumed_transaction_ids": [S], "state_digest": S, "detail_records": [S],
}
TEMPLATE_BINDINGS = {
    "executable_binary_digest": "executable_binary_digest",
    "loaded_image_policy_digest": "loaded_image_set_digest",
    "code_signing_policy_digest": "code_signing_identity_digest",
    "argv_digest": "effective_argv_digest",
    "environment_digest": "effective_environment_digest",
    "working_directory_digest": "working_directory_object_digest",
    "principal_identity_digest": "effective_principal_digest",
    "sandbox_profile_digest": "sandbox_profile_digest",
    "ipc_profile_digest": "ipc_profile_digest",
    "injection_controls_policy_digest": "injection_controls_digest",
    "measurement_policy_digest": "measurement_policy_digest",
}

# Independent anchors. Updating fixtures without deliberately updating these constants fails.
EXPECTED_POINTER_COUNT = 516
EXPECTED_POINTER_DIGEST = "ee8c98cba0272629f2acd5bbdff60a70013afd1a090d53aaff53ef2c4813a629"
EXPECTED_OPERATION_GOLDENS = {
    "advance_policy_evaluation": {
        "operation_digest": "16d138ccf140105e22d1065081fb07f25e5fd8bace0d6d1b71957d93adc18a60",
        "from_leaf_state_digest": "22cdc861dc8e6f0eafbdf1668c8dcdce9f0992e2dae12a98015de0e2c9fd7949",
        "target_leaf_digest": "48a6c8fbd0a4f4d1d1c3273c6e3d30544015e0fbd53e187bc309243097e2f6c7",
        "authorization_digest": "d6345c0dbc8c4ea7e259fc6fe46feea2cbaff0d8fb34bee69ef73177311a5584",
        "prepared_digest": "96f113913b85c92dd068f66cf30f86e277ee09ecee8c255abfbf24e7e69d2902",
    },
    "advance_installation_generation": {
        "operation_digest": "42280cfbe4df7121ba34c5603dc5d3488f1ac41512a0710fab9b6d039c776336",
        "from_leaf_state_digest": "09f74d5ae84fe2794f354829d82a304c7f35b022fb98a83b8253d3a41fdf6a10",
        "target_leaf_digest": "27d1634bf85257d1622bd32e767c6dff1fb38d0d98c81aaeccdb490298e55440",
        "authorization_digest": "9b43b45f0e70030a7ee6d3f93cc231ade2fe76f07911147a0c2bde6aa5748dc1",
        "prepared_digest": "e710eef593179bcdeb7af6ded34e609c99850c123fd53b4587279a93dbf5e68d",
    },
    "advance_time_high_water": {
        "operation_digest": "a09f3cf1999fca94b6da63c41e7eada8cf516c5e09647e3b20a35e4b8d6477c7",
        "from_leaf_state_digest": "32cfab379235a8e555063060eb5dfdb597c998b85fc4cb01252baa05867c7f43",
        "target_leaf_digest": "6c789d94b081aa1dafdf0136a93575ac9c2315ad68b7f065083dece5f6b0e032",
        "authorization_digest": "311027dd051217621c207a26c58040cdb52db27ce74ad806107cbe79eb51e089",
        "prepared_digest": "87a0f22118188b8ffe495567bc9bfb8aa2b882aeab917ded76e81c734efc1e63",
    },
    "reconcile_clock_epoch": {
        "operation_digest": "343504ec9a3c62e2e76479a20623340ed6f7dba5743ab2bfc61b68c81effdeaa",
        "from_leaf_state_digest": "cec86af6e4fb0a5e96652dd83ebf46b08e17a2330880b8ec744ace3be4df6ebc",
        "target_leaf_digest": "d94e92e16373c18653775df4dc3c72a43fbd3e7c34726a20a4d39a1f5d63a975",
        "authorization_digest": "6469091bc0a9aa17fb8b251ca91d3945e5895f72c1b77485a9bc71d961d04b91",
        "prepared_digest": "bf6d7cefb51a260172833ee47e5046a7daa273f0290b8341f01240e4c757a19e",
    },
}
EXPECTED_PROFILE_DIGEST = "79681e535df53a3139641dac2a5212d68c132375e75d19c916d05e66667f3cdf"
EXPECTED_TEMPLATE_DIGEST = "0b14de03e00d071f3f0776da1a16d391d5e34d16ca8ab2e7f243f212d499c74b"
EXPECTED_POLICY_DIGEST = "d543ed9e403d8231f82608fa03eaa4ea59c20407b766ca91f4d97ca259d88623"
EXPECTED_PEER_DIGEST = "07f1e50e7dd364db3fac15c5c9074024ca1637bd461b3cffd11c13d292f81352"
EXPECTED_REQUEST_DIGEST = "31542e6783c9832800fcbddc24dece2127bb6461f31b94854bcb5b1861e6c676"
EXPECTED_WINDOWS_DIGEST = "ee5b029b787fd8d3166a0480e3fd51e149112d9f7b908da4e4fa82c181916b7d"
EXPECTED_CONTRACT_DIGESTS = {
    MONOTONIC: "0e96e6649ebadf603ff039a4307a5249421b1bb8ad487989506648961fa47ca3",
    ATOMIC: "0ae62e53ca601b8e318ea7c59d888b5f99921df0b7cd63247b8017570f6a91ac",
    ANNEX: "bbaea1fd78216c1b4aece06c0906d161c263203fcd3e53a6314b71650c9b014a",
    TECH: "3fcb05887057692a36e7d3f2de14ec420659c90278ee9709a69668ada70ecae4",
    PRODUCT: "64c783ae0f1730bbe30ab7c6e44b142ab27d5efdc906dc90c8347cedf4ff22b5",
}
EXPECTED_NEGATIVES = {
    "authorization_unknown_operation", "authorization_variant_extra_field",
    "phase_operation_detached", "phase_from_state_detached", "phase_target_detached",
    "no_block_to_anchor_transition", "mode_unknown_null", "mode_extra_field",
    "whole_release_rollback_overclaim", "attestation_missing_loaded_image_set",
    "attestation_co_mutated_template", "attestation_co_mutated_peer",
    "attestation_co_mutated_challenge", "attestation_expired",
    "attestation_signature_extra_field", "peer_evidence_extra_field",
    "attestation_unsigned_self_report", "embedded_pointer_omitted",
    "windows_command_line_mutation", "windows_embedded_nul",
    "consumed_transaction_reuse_after_compaction", "tombstone_guard_deletion",
}


class ContractError(ValueError):
    pass


def canonical_bytes(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode()


def sha256(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def h(domain: str, body: object) -> str:
    return sha256(canonical_bytes({"digest_domain": domain, "schema_version": 1, "body": body}))


def validate_schema(value: object, schema: object, path: str = "root") -> None:
    if schema == S:
        if not isinstance(value, str):
            raise ContractError(f"type:{path}")
    elif schema == I:
        if not isinstance(value, int) or isinstance(value, bool):
            raise ContractError(f"type:{path}")
    elif isinstance(schema, list):
        if not isinstance(value, list) or not value:
            raise ContractError(f"array:{path}")
        for item in value:
            validate_schema(item, schema[0], path + "/items")
    elif isinstance(schema, dict):
        if not isinstance(value, dict) or set(value) != set(schema):
            raise ContractError(f"shape:{path}")
        for key, child in schema.items():
            validate_schema(value[key], child, path + "/" + key)
    else:
        raise AssertionError(f"bad schema at {path}")


def schema_leaves(root: str, schema: object) -> set[str]:
    if schema in (S, I):
        return {root}
    if isinstance(schema, list):
        return schema_leaves(root + "/items", schema[0])
    result = set()
    for key, child in schema.items():
        result |= schema_leaves(root + "/" + key, child)
    return result


def mutate_at(value: object, path: list[str], mode: str) -> object:
    changed = copy.deepcopy(value)
    parent = changed
    for component in path[:-1]:
        parent = parent[0] if component == "items" else parent[component]
    key = 0 if path[-1] == "items" else path[-1]
    if mode == "omit":
        if isinstance(parent, dict):
            del parent[key]
        else:
            parent.clear()
    elif mode == "wrong_type":
        parent[key] = 7 if isinstance(parent[key], str) else "wrong"
    else:
        if isinstance(parent, dict):
            parent[str(key) + "_alias"] = parent.pop(key)
        else:
            parent[0] = {"alias": parent[0]}
    return changed


def operation_transition(operation: dict) -> dict:
    variant = operation.get("variant")
    if variant not in OPERATION_SCHEMAS:
        raise ContractError("operation_variant")
    validate_schema(operation, OPERATION_SCHEMAS[variant], "authorized_operation")
    if operation["schema_version"] != 1:
        raise ContractError("operation_version")
    if variant == "advance_policy_evaluation":
        before, after = operation["from_policy_generation"], operation["target_policy_generation"]
        kind, scope, old = "policy_evaluation", "global", operation["committed_policy_digest"]
    elif variant == "advance_installation_generation":
        before, after = operation["from_installation_generation"], operation["target_installation_generation"]
        kind, scope, old = "installation_generation", operation["installation_scope_id"], operation["committed_installation_digest"]
    elif variant == "advance_time_high_water":
        before, after = operation["from_sequence"], operation["target_sequence"]
        kind, scope = "time_high_water", operation["installation_scope_id"]
        old = h("vibeguard.gh702.from-time-high-water.v1", {
            "clock_epoch": operation["clock_epoch"], "sequence": before,
            "high_water": operation["from_high_water"],
        })
        if operation["target_high_water"] < operation["from_high_water"]:
            raise ContractError("time_rollback")
    else:
        before, after = operation["from_clock_epoch"], operation["target_clock_epoch"]
        kind, scope, old = "clock_epoch", operation["installation_scope_id"], operation["reconciliation_evidence_digest"]
    if after != before + 1:
        raise ContractError("operation_successor")
    authority_id = h("vibeguard.gh702.per-leaf-authority-fixture.v1", {"leaf_kind": kind, "installation_scope_id": scope})
    from_state = {"per_leaf_authority_id": authority_id, "leaf_counter": before, "leaf_value_digest": old}
    target_value = h("vibeguard.gh702.authorized-operation-leaf-value.v1", operation)
    target = {"schema_version": 1, "target_leaf_counter": after, "target_leaf_value_digest": target_value}
    return {"operation": variant, "from_leaf_state": from_state, "target_leaf_body": target,
            "target_leaf_digest": sha256(b"vibeguard.gh702.anchor-target-leaf.v1\0" + canonical_bytes(target))}


def materialize_authorization(operation: dict) -> dict:
    transition = operation_transition(operation)
    operation_digest = h("vibeguard.gh702.authorized-anchor-operation.v1", operation)
    body = {"operation": transition["operation"], "authorized_operation_digest": operation_digest,
            "from_leaf_state": transition["from_leaf_state"],
            "target_leaf_body": transition["target_leaf_body"],
            "target_leaf_digest": transition["target_leaf_digest"]}
    return {"operation": transition["operation"], "authorized_operation": copy.deepcopy(operation),
            "authorized_operation_digest": operation_digest, "from_leaf_state": transition["from_leaf_state"],
            "target_leaf_body": transition["target_leaf_body"], "target_leaf_digest": transition["target_leaf_digest"],
            "target_authorization_digest": h("vibeguard.gh702.anchor-target-authorization.v1", body)}


def materialize_prepared(authorization: dict, mirror_digest: str) -> dict:
    return {"digest_domain": "vibeguard.gh702.anchor-phase-prepared.v1", "phase": "prepared",
            "schema_version": 1, "operation": authorization["operation"],
            "target_authorization_digest": authorization["target_authorization_digest"],
            "mirror_file_digest": mirror_digest, "from_leaf_state": authorization["from_leaf_state"],
            "target_leaf_body": authorization["target_leaf_body"],
            "target_leaf_digest": authorization["target_leaf_digest"]}


def authorization_golden(operation: dict, mirror_digest: str) -> dict:
    authorization = materialize_authorization(operation)
    prepared = materialize_prepared(authorization, mirror_digest)
    return {"operation_digest": authorization["authorized_operation_digest"],
            "from_leaf_state_digest": sha256(canonical_bytes(authorization["from_leaf_state"])),
            "target_leaf_digest": authorization["target_leaf_digest"],
            "authorization_digest": authorization["target_authorization_digest"],
            "prepared_digest": sha256(canonical_bytes(prepared))}


def validate_authorization(value: dict, expected_operation: dict) -> None:
    if value != materialize_authorization(expected_operation):
        raise ContractError("authorization_binding")


def validate_prepared(value: dict, authorization: dict, mirror_digest: str) -> None:
    if value != materialize_prepared(authorization, mirror_digest):
        raise ContractError("prepared_binding")


def validate_registry(previous: dict, candidate: dict, guarantee: str) -> None:
    if set(previous) != {"platform_id", "generation", "mode", "transition_policy", "state_survives"}:
        raise ContractError("previous_registry_shape")
    if set(candidate) != {"platform_id", "generation", "mode", "transition_policy"}:
        raise ContractError("candidate_registry_shape")
    if guarantee != "not_claimed_without_external_authority":
        raise ContractError("whole_release_overclaim")
    for value in (previous, candidate):
        if value["mode"] not in MODE_PAIRS or MODE_PAIRS[value["mode"]] != value["transition_policy"]:
            raise ContractError("mode_pair")
    if previous["platform_id"] != candidate["platform_id"]:
        raise ContractError("platform")
    if candidate["generation"] < previous["generation"] and previous["state_survives"]:
        raise ContractError("rollback")
    if previous["mode"] == "authenticated_no_block_v1" and candidate["mode"] != previous["mode"]:
        raise ContractError("terminal_transition")


def fixture_signature(key: bytes, digest: str) -> str:
    return sha256(key + bytes.fromhex(digest))


def parse_time(value: str) -> datetime:
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ContractError("attestation_time") from exc


def validate_launch(launch: dict) -> None:
    expected_launch_keys = {
        "profile", "profile_digest", "approved_adapter_process_template",
        "approved_adapter_process_template_digest", "policy", "policy_digest",
        "peer_evidence", "launch_request_identity", "launch_request_identity_digest",
        "validation_time", "adapter_process_attestation_envelope",
    }
    if set(launch) != expected_launch_keys:
        raise ContractError("launch_fixture_shape")
    profile, template, policy = launch["profile"], launch["approved_adapter_process_template"], launch["policy"]
    validate_schema(profile, PROFILE_SCHEMA, "launch_authority_profile_body")
    validate_schema(template, TEMPLATE_SCHEMA, "approved_adapter_process_template_body")
    validate_schema(policy, POLICY_SCHEMA, "launch_policy_body")
    profile_digest = h("vibeguard.gh702.launch-authority-profile-fixture.v1", profile)
    template_digest = h("vibeguard.gh702.approved-adapter-process-template.v1", template)
    if (profile_digest, template_digest) != (EXPECTED_PROFILE_DIGEST, EXPECTED_TEMPLATE_DIGEST):
        raise ContractError("owner_anchor")
    if launch["profile_digest"] != profile_digest or launch["approved_adapter_process_template_digest"] != template_digest:
        raise ContractError("owner_digest")
    if policy["launch_authority_profile_digest"] != profile_digest or policy["approved_adapter_process_template_digest"] != template_digest:
        raise ContractError("policy_owner_binding")
    policy_digest = h("vibeguard.gh702.launch-policy-fixture.v1", policy)
    if policy_digest != EXPECTED_POLICY_DIGEST or launch["policy_digest"] != policy_digest:
        raise ContractError("policy_anchor")
    if policy["approved_host_adapter_binary"]["binary_digest"] != template["executable_binary_digest"]:
        raise ContractError("adapter_binary_binding")
    request = launch["launch_request_identity"]
    validate_schema(request, REQUEST_SCHEMA, "launch_request_identity")
    request_digest = h("vibeguard.gh702.launch-request-identity-fixture.v1", request)
    if request_digest != EXPECTED_REQUEST_DIGEST or launch["launch_request_identity_digest"] != request_digest:
        raise ContractError("request_anchor")
    peer = launch["peer_evidence"]
    validate_schema(peer, PEER_SCHEMA, "peer_evidence")
    peer_body = {key: value for key, value in peer.items() if key != "peer_evidence_digest"}
    peer_digest = h("vibeguard.gh702.peer-evidence-fixture.v1", peer_body)
    if peer_digest != EXPECTED_PEER_DIGEST or peer["peer_evidence_digest"] != peer_digest:
        raise ContractError("peer_anchor")
    envelope = launch["adapter_process_attestation_envelope"]
    validate_schema(envelope, ATTESTATION_SCHEMA, "adapter_process_attestation_envelope")
    if envelope["digest_domain"] != "vibeguard.gh702.adapter-process-attestation.v1" or envelope["schema_version"] != 1:
        raise ContractError("attestation_envelope")
    body = envelope["body"]
    if body["launch_request_identity_digest"] != request_digest or body["peer_evidence_digest"] != peer_digest:
        raise ContractError("attestation_evidence_binding")
    for key in REQUEST_SCHEMA:
        if body[key] != request[key]:
            raise ContractError(f"request_binding:{key}")
    for key in ("authenticated_peer_process_id", "process_start_identity"):
        if body[key] != peer[key]:
            raise ContractError(f"peer_binding:{key}")
    if body["launch_authority_profile_digest"] != profile_digest or body["launch_policy_digest"] != policy_digest:
        raise ContractError("attestation_policy_binding")
    if body["launch_authority_backend_identity"] != profile["launch_authority_backend_identity"]:
        raise ContractError("backend_binding")
    for template_key, body_key in TEMPLATE_BINDINGS.items():
        if body[body_key] != template[template_key]:
            raise ContractError(f"template_binding:{template_key}")
    measured, expires = parse_time(body["measured_at"]), parse_time(body["expires_at"])
    validation_time = parse_time(launch["validation_time"])
    validity_ms = int((expires - measured).total_seconds() * 1000)
    if not measured <= validation_time <= expires:
        raise ContractError("attestation_expired")
    if validity_ms < 0 or validity_ms > profile["max_attestation_validity_ms"]:
        raise ContractError("attestation_validity")
    digest = h("vibeguard.gh702.adapter-process-attestation.v1", body)
    if envelope["attestation_digest"] != digest:
        raise ContractError("attestation_digest")
    signers = {item["signer_key_id"]: item for item in profile["trusted_signers"]}
    if set(signers) != set(SIGNER_KEYS) or profile["signature_quorum"] != 2:
        raise ContractError("profile_signers")
    seen = set()
    for signature in envelope["signatures"]:
        signer = signature["signer_key_id"]
        if signer in seen or signer not in signers:
            raise ContractError("signature_signer")
        seen.add(signer)
        profile_signer = signers[signer]
        if profile_signer["signature_algorithm"] != "fixture_sha256_binding_v1":
            raise ContractError("test_fixture_algorithm")
        if profile_signer["verification_key_digest"] != sha256(SIGNER_KEYS[signer]):
            raise ContractError("signer_key_anchor")
        if signature["signature_algorithm"] != profile_signer["signature_algorithm"]:
            raise ContractError("signature_algorithm")
        if signature["signature"] != fixture_signature(SIGNER_KEYS[signer], digest):
            raise ContractError("signature")
    if len(seen) < profile["signature_quorum"]:
        raise ContractError("signature_quorum")


def extract_list(text: str, name: str) -> list[str]:
    start = text.index(name + " = [")
    end = text.index("\n]", start)
    return re.findall(r'"(/[^"\n]+)"', text[start:end])


def draft_schemas() -> dict[str, object]:
    result = {f"/authorized_operation/{variant}": schema for variant, schema in OPERATION_SCHEMAS.items()}
    result.update({
        "/launch_authority_profile_body": PROFILE_SCHEMA,
        "/approved_adapter_process_template_body": TEMPLATE_SCHEMA,
        "/launch_policy_body": POLICY_SCHEMA,
        "/peer_evidence": PEER_SCHEMA,
        "/launch_request_identity": REQUEST_SCHEMA,
        "/adapter_process_attestation_envelope": ATTESTATION_SCHEMA,
        "/windows_serialization": WINDOWS_SCHEMA,
        "/consumed_transaction_reuse_guard_state": TOMBSTONE_SCHEMA,
    })
    return result


def generated_schema_registry() -> dict[str, object]:
    result = draft_schemas()
    prefix = "/h010_decision_envelope/h010_decision_body/platform_profiles/items/anchor_profile"
    result[prefix + "/launch_authority_profile_body"] = PROFILE_SCHEMA
    result[prefix + "/launch_policy_body"] = POLICY_SCHEMA
    return result


def generated_schema_pointers() -> set[str]:
    result = set()
    for root, schema in generated_schema_registry().items():
        result |= schema_leaves(root, schema)
    return result


def compile_pointer_registry() -> set[str]:
    annex = ANNEX.read_text()
    anchor = set(extract_list(annex, "anchor_identity_schema_pointers"))
    h010 = set(extract_list(annex, "h010_identity_schema_pointers"))
    return anchor | h010 | generated_schema_pointers()


def validate_pointer_registry(candidate: set[str]) -> None:
    if any(pointer.endswith(("_body", "_envelope", "_state")) for pointer in candidate):
        raise ContractError("pointer_object_root")
    digest = sha256("\n".join(sorted(candidate)).encode())
    if len(candidate) != EXPECTED_POINTER_COUNT or digest != EXPECTED_POINTER_DIGEST:
        raise ContractError("pointer_registry")


def quote_windows_argument(value: str) -> str:
    result, slashes = ['"'], 0
    for char in value:
        if char == "\\":
            slashes += 1
        elif char == '"':
            result.extend(("\\" * (slashes * 2 + 1), '"'))
            slashes = 0
        else:
            result.extend(("\\" * slashes, char))
            slashes = 0
    result.extend(("\\" * (slashes * 2), '"'))
    return "".join(result)


def windows_command_bytes(arguments: list[str]) -> bytes:
    if not arguments or any(not isinstance(value, str) or "\x00" in value for value in arguments):
        raise ContractError("windows_arguments")
    return " ".join(quote_windows_argument(value) for value in arguments).encode("utf-16le")


def validate_windows(value: dict) -> None:
    validate_schema(value, WINDOWS_SCHEMA, "windows_serialization")
    raw = windows_command_bytes(value["arguments"])
    encoded = base64.urlsafe_b64encode(raw).decode().rstrip("=")
    if "=" in value["command_line_base64url"] or encoded != value["command_line_base64url"]:
        raise ContractError("windows_serialization")
    if len(raw) % 2 or raw.endswith(b"\x00\x00"):
        raise ContractError("windows_native_bytes")
    if sha256(raw) != EXPECTED_WINDOWS_DIGEST or value["command_line_sha256"] != EXPECTED_WINDOWS_DIGEST:
        raise ContractError("windows_golden")


def tombstone_digest(value: dict) -> str:
    body = {key: item for key, item in value.items() if key != "state_digest"}
    return h("vibeguard.gh702.consumed-transaction-reuse-guard-state.v1", body)


def validate_tombstone_transition(previous: dict, current: dict) -> None:
    for label, state in (("previous", previous), ("current", current)):
        if not isinstance(state, dict) or set(state) != set(TOMBSTONE_SCHEMA):
            raise ContractError(f"tombstone_shape:{label}")
        for key in ("reuse_guard_generation",):
            if not isinstance(state[key], int) or isinstance(state[key], bool):
                raise ContractError(f"tombstone_type:{label}:{key}")
        for key in ("previous_state_digest", "state_digest"):
            if not isinstance(state[key], str):
                raise ContractError(f"tombstone_type:{label}:{key}")
        for key in ("durable_consumed_transaction_ids", "detail_records"):
            if not isinstance(state[key], list) or any(not isinstance(item, str) for item in state[key]):
                raise ContractError(f"tombstone_type:{label}:{key}")
    if previous["state_digest"] != tombstone_digest(previous) or current["state_digest"] != tombstone_digest(current):
        raise ContractError("tombstone_digest")
    if current["previous_state_digest"] != previous["state_digest"]:
        raise ContractError("tombstone_predecessor")
    if current["reuse_guard_generation"] != previous["reuse_guard_generation"] + 1:
        raise ContractError("tombstone_generation")
    if not set(previous["durable_consumed_transaction_ids"]) <= set(current["durable_consumed_transaction_ids"]):
        raise ContractError("tombstone_nonrollback")


def validate_transaction_candidate(candidate: str, state: dict) -> None:
    if candidate in state["durable_consumed_transaction_ids"]:
        raise ContractError("transaction_reuse")


def validate_contract_text() -> None:
    required = {
        MONOTONIC: ("authorized_operation = one_of_exact(", "prepared object 的 `operation`", "本 Draft 明确**不提供**"),
        ATOMIC: ("adapter_process_attestation_envelope = {", "loaded_image_set_digest",
                 "approved_adapter_process_template_digest", "authenticated_channel_binding_digest"),
        ANNEX: ("embedded_identity_schema_pointers", "all_identity_schema_pointers = exact_set_union(",
                "anchor_identity_verification_contract_digest", "不声称抵抗 coherent whole-release rollback"),
        TECH: ("bash tests/test_gh702_anchor_contract.sh",),
        PRODUCT: ("conforming release", "coherent whole-release rollback"),
    }
    for path, snippets in required.items():
        text = path.read_text()
        if sha256(text.encode()) != EXPECTED_CONTRACT_DIGESTS[path]:
            raise ContractError(f"contract_digest:{path.name}")
        if len(text.splitlines()) > 800:
            raise ContractError(f"u16:{path.name}")
        for snippet in snippets:
            if snippet not in text:
                raise ContractError(f"contract_text:{path.name}:{snippet}")


def resign_attestation(launch: dict) -> None:
    envelope = launch["adapter_process_attestation_envelope"]
    digest = h("vibeguard.gh702.adapter-process-attestation.v1", envelope["body"])
    envelope["attestation_digest"] = digest
    for item in envelope["signatures"]:
        item["signature"] = fixture_signature(SIGNER_KEYS[item["signer_key_id"]], digest)


def rematerialize_launch_owner_chain(launch: dict) -> None:
    template_digest = h("vibeguard.gh702.approved-adapter-process-template.v1",
                        launch["approved_adapter_process_template"])
    launch["approved_adapter_process_template_digest"] = template_digest
    launch["policy"]["approved_adapter_process_template_digest"] = template_digest
    policy_digest = h("vibeguard.gh702.launch-policy-fixture.v1", launch["policy"])
    launch["policy_digest"] = policy_digest
    launch["adapter_process_attestation_envelope"]["body"]["launch_policy_digest"] = policy_digest
    resign_attestation(launch)


def validate_negative(name: str, vectors: dict, pointers: set[str]) -> None:
    try:
        operations = vectors["operation_examples"]
        authorization = vectors["authorizations"]["advance_installation_generation"]
        prepared = vectors["prepared_phases"]["advance_installation_generation"]
        mirror = vectors["mirror_file_digest"]
        if name == "authorization_unknown_operation":
            value = copy.deepcopy(operations[1]); value["variant"] = "advance_registry"; operation_transition(value)
        elif name == "authorization_variant_extra_field":
            value = copy.deepcopy(operations[1]); value["extra"] = 1; operation_transition(value)
        elif name == "phase_operation_detached":
            value = copy.deepcopy(prepared); value["operation"] = "advance_time_high_water"; validate_prepared(value, authorization, mirror)
        elif name == "phase_from_state_detached":
            value = copy.deepcopy(prepared); value["from_leaf_state"]["leaf_counter"] -= 1; validate_prepared(value, authorization, mirror)
        elif name == "phase_target_detached":
            value = copy.deepcopy(prepared); value["target_leaf_body"]["target_leaf_counter"] += 1; validate_prepared(value, authorization, mirror)
        elif name == "no_block_to_anchor_transition":
            value = copy.deepcopy(vectors["registry"]["successor"]); value.update(mode="anchor_block_v1", transition_policy="external_launch_floor_anchor_v1"); validate_registry(vectors["registry"]["persisted_observation"], value, vectors["registry"]["whole_release_rollback_guarantee"])
        elif name == "mode_unknown_null":
            value = copy.deepcopy(vectors["registry"]["successor"]); value.update(mode="future_unknown", transition_policy=None); validate_registry(vectors["registry"]["persisted_observation"], value, vectors["registry"]["whole_release_rollback_guarantee"])
        elif name == "mode_extra_field":
            value = copy.deepcopy(vectors["registry"]["successor"]); value["alias"] = "no-block"; validate_registry(vectors["registry"]["persisted_observation"], value, vectors["registry"]["whole_release_rollback_guarantee"])
        elif name == "whole_release_rollback_overclaim":
            validate_registry(vectors["registry"]["persisted_observation"], vectors["registry"]["successor"], "protected_by_local_leaf")
        elif name.startswith("attestation_") or name == "peer_evidence_extra_field":
            value = copy.deepcopy(vectors["launch"])
            envelope, body = value["adapter_process_attestation_envelope"], value["adapter_process_attestation_envelope"]["body"]
            if name == "attestation_missing_loaded_image_set": del body["loaded_image_set_digest"]
            elif name == "attestation_co_mutated_template":
                changed = "sha256:" + "ab" * 32; value["approved_adapter_process_template"]["loaded_image_policy_digest"] = changed; body["loaded_image_set_digest"] = changed; rematerialize_launch_owner_chain(value)
            elif name == "attestation_co_mutated_peer":
                value["peer_evidence"]["authenticated_peer_process_id"] = body["authenticated_peer_process_id"] = "pid:9999"; peer_body = {key: item for key, item in value["peer_evidence"].items() if key != "peer_evidence_digest"}; value["peer_evidence"]["peer_evidence_digest"] = body["peer_evidence_digest"] = h("vibeguard.gh702.peer-evidence-fixture.v1", peer_body); resign_attestation(value)
            elif name == "attestation_co_mutated_challenge":
                for item in (value["launch_request_identity"], value["peer_evidence"], body): item["challenge_nonce"] = "nonce-evil"
                request_digest = h("vibeguard.gh702.launch-request-identity-fixture.v1", value["launch_request_identity"]); value["launch_request_identity_digest"] = body["launch_request_identity_digest"] = request_digest
                peer_body = {key: item for key, item in value["peer_evidence"].items() if key != "peer_evidence_digest"}; value["peer_evidence"]["peer_evidence_digest"] = body["peer_evidence_digest"] = h("vibeguard.gh702.peer-evidence-fixture.v1", peer_body); resign_attestation(value)
            elif name == "attestation_expired": value["validation_time"] = "2026-08-09T00:00:31Z"
            elif name == "attestation_signature_extra_field": envelope["signatures"][0]["extra"] = 1
            elif name == "peer_evidence_extra_field": value["peer_evidence"]["extra"] = 1
            else: envelope["signatures"] = []
            validate_launch(value)
        elif name == "embedded_pointer_omitted":
            value = set(pointers); value.remove(next(item for item in value if "/anchor_profile/launch_policy_body/" in item)); validate_pointer_registry(value)
        elif name == "windows_command_line_mutation":
            value = copy.deepcopy(vectors["windows_serialization"]); value["command_line_base64url"] = "A" + value["command_line_base64url"][1:]; validate_windows(value)
        elif name == "windows_embedded_nul":
            value = copy.deepcopy(vectors["windows_serialization"]); value["arguments"][1] = "--session\x00evil"; validate_windows(value)
        elif name == "consumed_transaction_reuse_after_compaction":
            validate_transaction_candidate("launch-0007", vectors["tombstone_current"])
        elif name == "tombstone_guard_deletion":
            previous, current = vectors["tombstone_previous"], copy.deepcopy(vectors["tombstone_current"]); current["durable_consumed_transaction_ids"] = []; current["state_digest"] = tombstone_digest(current); validate_tombstone_transition(previous, current)
        else:
            raise AssertionError(f"unknown negative: {name}")
    except ContractError:
        return
    raise AssertionError(f"negative unexpectedly accepted: {name}")


def validate_schema_mutations(vectors: dict) -> int:
    cases = []
    operations = vectors["operation_examples"]
    for operation in operations:
        cases.append((f"/authorized_operation/{operation['variant']}", OPERATION_SCHEMAS[operation["variant"]], operation))
    launch = vectors["launch"]
    embedded = vectors["embedded_h010_anchor_profile"]
    if embedded != {"launch_authority_profile_body": launch["profile"],
                    "launch_policy_body": launch["policy"]}:
        raise ContractError("embedded_h010_binding")
    cases.extend([
        ("/launch_authority_profile_body", PROFILE_SCHEMA, launch["profile"]),
        ("/approved_adapter_process_template_body", TEMPLATE_SCHEMA, launch["approved_adapter_process_template"]),
        ("/launch_policy_body", POLICY_SCHEMA, launch["policy"]),
        ("/peer_evidence", PEER_SCHEMA, launch["peer_evidence"]),
        ("/launch_request_identity", REQUEST_SCHEMA, launch["launch_request_identity"]),
        ("/adapter_process_attestation_envelope", ATTESTATION_SCHEMA, launch["adapter_process_attestation_envelope"]),
        ("/windows_serialization", WINDOWS_SCHEMA, vectors["windows_serialization"]),
        ("/consumed_transaction_reuse_guard_state", TOMBSTONE_SCHEMA, vectors["tombstone_previous"]),
    ])
    prefix = "/h010_decision_envelope/h010_decision_body/platform_profiles/items/anchor_profile"
    cases.extend([
        (prefix + "/launch_authority_profile_body", PROFILE_SCHEMA,
         embedded["launch_authority_profile_body"]),
        (prefix + "/launch_policy_body", POLICY_SCHEMA, embedded["launch_policy_body"]),
    ])
    count, covered = 0, set()
    for root, schema, value in cases:
        validate_schema(value, schema, root)
        for pointer in schema_leaves(root, schema):
            covered.add(pointer)
            relative = pointer[len(root) + 1:].split("/")
            for mode in ("omit", "wrong_type", "alias"):
                try:
                    validate_schema(mutate_at(value, relative, mode), schema, root)
                except ContractError:
                    count += 1
                else:
                    raise AssertionError(f"schema mutation accepted:{pointer}:{mode}")
    if covered != generated_schema_pointers():
        raise ContractError("schema_mutation_coverage")
    return count


def main() -> None:
    vectors = json.loads(VECTORS.read_text())
    if vectors["schema_version"] != 1:
        raise ContractError("schema_version")
    validate_contract_text()
    mirror = vectors["mirror_file_digest"]
    computed_goldens = {}
    for operation in vectors["operation_examples"]:
        authorization = materialize_authorization(operation)
        prepared = materialize_prepared(authorization, mirror)
        variant = operation["variant"]
        validate_authorization(vectors["authorizations"][variant], operation)
        validate_prepared(vectors["prepared_phases"][variant], authorization, mirror)
        computed_goldens[variant] = authorization_golden(operation, mirror)
    if computed_goldens != EXPECTED_OPERATION_GOLDENS or vectors["operation_goldens"] != EXPECTED_OPERATION_GOLDENS:
        raise ContractError("operation_goldens")
    registry = vectors["registry"]
    validate_registry(registry["persisted_observation"], registry["successor"], registry["whole_release_rollback_guarantee"])
    validate_launch(vectors["launch"])
    pointers = compile_pointer_registry()
    validate_pointer_registry(pointers)
    validate_windows(vectors["windows_serialization"])
    validate_tombstone_transition(vectors["tombstone_previous"], vectors["tombstone_current"])
    validate_transaction_candidate("launch-0008", vectors["tombstone_current"])
    mutation_count = validate_schema_mutations(vectors)
    if set(vectors["negative_corpus"]) != EXPECTED_NEGATIVES:
        raise ContractError("negative_inventory")
    for name in vectors["negative_corpus"]:
        validate_negative(name, vectors, pointers)
    print("GH702_ANCHOR_CONTRACT_OK "
          f"operations={len(OPERATION_SCHEMAS)} modes={len(MODE_PAIRS)} pointers={len(pointers)} "
          f"schema_mutations={mutation_count} negatives={len(EXPECTED_NEGATIVES)}")


if __name__ == "__main__":
    main()

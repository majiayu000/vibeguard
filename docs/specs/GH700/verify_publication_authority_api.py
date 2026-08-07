#!/usr/bin/env python3
"""Stdlib-only semantic verifier for the GH700 authority API artifacts."""

import argparse
import base64
import copy
import hashlib
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from publication_authorization_semantics import (
    AUTH_KEYS, check_binding_matrix_mutations, check_profile_selectors, check_row_contract_fields,
    derive_authorization_fields,
    relation_mutations, row_for_model,
    validate_binding_matrix, validate_common_bindings, validate_pair_bindings,
)
from publication_digest_domains import allowed_domains, check_contextual_domain_rejections, require_domain, validate_domain_sets
from publication_schema_validator import make_validator
from publication_structural_mutations import check_structural_mutations
from publication_wire_registries import (
    SIGNING_BRANCHES, anchor_digest, check_error_branches, check_registry_anchor_mutations,
    check_registry_anchors,
)
from publication_typed_contracts import (
    bind_nested_receipts, check_nested_kms_mutations, materialize_kms_manifest, validate_nested_capsules,
)

SAFE_MAX = 9_007_199_254_740_991
U64_MAX = 18_446_744_073_709_551_615
CLIENT = ("get_publication_head", "claim_publication_owner", "renew_publication_owner", "takeover_publication_owner", "append_publication_transition", "plan_release_mutation", "deliver_release_mutation", "recover_release_mutation", "plan_generated_pr", "deliver_generated_pr", "recover_generated_pr", "append_blocked_attempt", "bind_blocked_attempt", "list_blocked_attempts", "commit_reconciliation_watermark", "get_blocked_attempt_frontier", "read_secret_capsule")
CONTROL = ("prepare_bootstrap_trusted_time", "bootstrap", "migrate", "recover", "ready")
COVERAGE = {"source_binding", "genesis", "key_attestation", "client_replay", "control_replay", "terminal_binding", "snapshot_binding", "merged_existing_receipts", "recover_selector_database", "recover_selector_backup", "recover_selector_anchor", "control_not_found", "prebootstrap_policy", "release_recovery_pending", "release_not_applied", "release_compensated", "release_blocked", "generated_pr_not_applied", "generated_pr_blocked", "delivery_recovery_required", "capsule_source_plan", "capsule_source_claim"}
REQUIRED_DIGEST_NODES = {"attempt_subject_key", "kms_encryption_context_digest", "release_identity_attestation_digest", "liveness_policy_digest", "authorization_signing_preimage_digest", "signature_digest", "client_request_nonce_digest", "control_request_nonce_digest", "time_bound_request_id", "execution_identity_digest", "operation_id", "release_broker_delivery_id", "generated_pr_delivery_id", "delivery_scope_digest", "recovery_query_digest", "capsule_source_request_id", "secret_channel_request_core_digest", "tls_exporter_context_digest", "tls_exporter_keying_material_digest", "secret_channel_binding_digest", "operation_request_digest", "receipt_digest", "result_digest", "response_nonce_digest", "response_digest", "prior_anchor_binding_digest", "backup_aad_digest", "describe_key_material_attestation_digest", "manifest_key_binding_digest", "generate_data_key_request_digest", "generate_data_key_material_attestation_digest", "key_attestation_digest", "capsule_receipt_digest", "replay_row_digest"}
DIGEST_SCHEMA = None
KMS_MANIFEST = None
BINDING_MATRIX = None


class ContractError(Exception):
    pass


def pairs_no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ContractError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load(path):
    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=pairs_no_duplicates)
    except (OSError, json.JSONDecodeError) as exc:
        raise ContractError(f"cannot load {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ContractError(f"top-level object required: {path}")
    return value


def walk(value):
    yield value
    children = value.values() if isinstance(value, dict) else value if isinstance(value, (list, tuple)) else ()
    for child in children:
        yield from walk(child)


def jcs(value):
    for item in walk(value):
        if isinstance(item, float):
            raise ContractError("floating-point canonical input forbidden")
        if isinstance(item, int) and not isinstance(item, bool) and abs(item) > SAFE_MAX:
            raise ContractError("unsafe JSON integer in canonical input")
    return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":"), sort_keys=True).encode()


def sha(raw):
    return "sha256:" + hashlib.sha256(raw).hexdigest()


def dg(node, domain, preimage, schema=None, context=None):
    if not isinstance(preimage, dict) or "v" in preimage:
        raise ContractError("digest preimage must be an object without a caller-supplied v")
    owned = require_domain(schema or DIGEST_SCHEMA, node, domain, ContractError, context)
    return sha(jcs({"v": owned, **preimage}))


def b64u(raw):
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def decode_b64u(value, size, label):
    if not isinstance(value, str) or "=" in value or re.fullmatch(r"[A-Za-z0-9_-]+", value) is None:
        raise ContractError(f"{label}: canonical unpadded base64url required")
    try:
        raw = base64.b64decode(value + "=" * ((-len(value)) % 4), altchars=b"-_", validate=True)
    except ValueError as exc:
        raise ContractError(f"{label}: invalid base64url") from exc
    if len(raw) != size or b64u(raw) != value:
        raise ContractError(f"{label}: decoded length or byte-identical re-encode mismatch")
    return raw


def uint64(value, label):
    if isinstance(value, bool):
        raise ContractError(f"{label}: bool is not uint64")
    if isinstance(value, int):
        if 0 <= value <= SAFE_MAX:
            return value
        raise ContractError(f"{label}: JSON number outside safe uint64 range")
    if not isinstance(value, str) or re.fullmatch(r"0|[1-9][0-9]*", value) is None:
        raise ContractError(f"{label}: canonical decimal required")
    number = int(value)
    if number <= SAFE_MAX or number > U64_MAX:
        raise ContractError(f"{label}: decimal uint64 outside safe-max+1..2^64-1")
    return number


pointer, is_type, valid, validate = make_validator(ContractError, uint64, jcs)


def expand(value, fixtures, stack=()):
    if isinstance(value, list):
        return [expand(item, fixtures, stack) for item in value]
    if isinstance(value, dict):
        if set(value) == {"$fixture"}:
            name = value["$fixture"]
            if name not in fixtures or name in stack:
                raise ContractError(f"bad fixture: {name}")
            return expand(copy.deepcopy(fixtures[name]), fixtures, stack + (name,))
        return {key: expand(item, fixtures, stack) for key, item in value.items()}
    return value


def context(value, values):
    if isinstance(value, list):
        return [context(item, values) for item in value]
    if isinstance(value, dict):
        if set(value) == {"$context"}:
            if value["$context"] not in values:
                raise ContractError(f"missing context {value['$context']}")
            return copy.deepcopy(values[value["$context"]])
        return {key: context(item, values) for key, item in value.items()}
    return value


def derive(container, key, expected, label):
    if container.get(key) == {"$derive": key}:
        container[key] = expected
    elif container.get(key) != expected:
        raise ContractError(f"{label}: {key} mismatch")


def strip_ids(value):
    if isinstance(value, list):
        return [strip_ids(item) for item in value]
    if not isinstance(value, dict):
        return value
    # Derived assertions never feed operation_id: expected_attempt_subject_key
    # is a byte-equal restatement of the authority-derived subject, not an
    # authority input, so the closed attempt_subject payload is what binds.
    omitted = set(AUTH_KEYS) | {"time_bound_request_id", "control_operation_id", "broker_delivery_id", "generated_pr_delivery_id", "recovery_query_digest", "secret_channel_binding", "expected_attempt_subject_key"}
    return {key: strip_ids(item) for key, item in value.items() if key not in omitted}


def operation_id(request, surface):
    return dg("operation_id", "GH700:operation-id:v1", {
        "surface": surface, "method": request["method"], "authority_id": request["authority_id"], "repo_node_id": request["repo_node_id"],
        "expected_publication_frontier_or_null": request.get("expected_publication_frontier_or_null"),
        "expected_blocked_attempt_frontier_or_null": request.get("expected_blocked_attempt_frontier_or_null"), "subject": strip_ids(request["body"]),
    })


SIGNING_MANIFEST = None


def require_pinned_signing_key(container, label, role):
    """Every signature must name the active manifest key for its role.

    Recomputing the signing preimage and hashing the signature bytes proves
    self-consistency, not authority: without this, a caller can construct
    matching principal/policy/method fields, attach an arbitrary canonical
    64-byte signature under a key of their choosing, and still verify.

    This gate pins key identity. It does not perform the asymmetric signature
    check itself — that needs a real verifier over the pinned public key and is
    outside what a stdlib-only conformance gate can prove.
    """
    if SIGNING_MANIFEST is None:
        raise ContractError(f"{label}: signing manifest is not loaded")
    expected_id = SIGNING_MANIFEST[f"{role}_signing_key_id"]
    expected_material = SIGNING_MANIFEST[f"{role}_signing_key_material_id"]
    if container.get("signing_key_id") != expected_id:
        raise ContractError(f"{label}: signing_key_id is not the active {role} key")
    if container.get("signing_key_material_id") != expected_material:
        raise ContractError(f"{label}: signing_key_material_id is not the active {role} key")


def auth_digest(auth, label):
    require_pinned_signing_key(auth, label, "authorization")
    raw_signature = decode_b64u(auth["signature_b64u"], 64, f"{label}.signature_b64u")
    require_domain(DIGEST_SCHEMA, "signature_digest", None, ContractError); derive(auth, "signature_digest", sha(raw_signature), label)
    preimage = {key: item for key, item in auth.items() if key not in {"signing_preimage_digest", "signature_b64u", "signature_digest"}}
    derive(auth, "signing_preimage_digest", dg(
        "authorization_signing_preimage_digest",
        auth["schema_version"].replace(":v1", ":signing-preimage:v1"), preimage,
        context=auth["schema_version"],
    ), label)


def receipt_digests(value, label="result"):
    if isinstance(value, list):
        for index, item in enumerate(value):
            receipt_digests(item, f"{label}[{index}]")
        return
    if not isinstance(value, dict):
        return
    for key, item in value.items():
        receipt_digests(item, f"{label}.{key}")
    if "receipt_version" in value:
        derive(value, "receipt_digest", dg("receipt_digest", value["receipt_version"], {key: item for key, item in value.items() if key != "receipt_digest"}, context=value["receipt_version"]), label)
    if "capsule_receipt_version" in value:
        derive(value, "key_attestation_digest", dg("key_attestation_digest", "GH700:authority-capsule-key-attestation-digest:v1", value["key_attestation"]), label)
        derive(value, "capsule_receipt_digest", dg("capsule_receipt_digest", value["capsule_receipt_version"], {key: item for key, item in value.items() if key != "capsule_receipt_digest"}), label)


def request_digests(request, surface):
    method, body = request["method"], request["body"]
    nonce = decode_b64u(request["request_nonce"], 32, f"{method}.request_nonce")
    if "release_identity_attestation" in body:
        # An unconstrained attestation_digest let the release identity, process,
        # key, and validity fields be rewritten while the proof bundle merely
        # copied the digest through. Bind the digest to the attestation content.
        attestation = body["release_identity_attestation"]
        require_pinned_signing_key(attestation, method, "release_identity")
        derive(attestation, "attestation_digest", dg(
            "release_identity_attestation_digest", "GH700:release-identity-attestation:v1",
            {key: item for key, item in attestation.items() if key != "attestation_digest"},
        ), method)
    if "time_bound_intent" in body:
        # Derived before operation_id: the intent (policy digest included) binds
        # the operation, so both verification passes must see the same bytes.
        intent = body["time_bound_intent"]
        derive(intent["client_payload_core"], "liveness_policy_digest", dg(
            "liveness_policy_digest", "GH700:liveness-policy:v1", intent["liveness_policy"],
        ), method)
    op_id = operation_id(request, surface)
    if "time_bound_request_id" in body:
        intent = body["time_bound_intent"]
        time_id = dg("time_bound_request_id", "GH700:time-bound-request-id:v1", intent)
        derive(body, "time_bound_request_id", time_id, method)
        auth = body["publication_lease_authorization"]
        derive(auth, "authorized_time_bound_request_id", time_id, method)
        derive(auth, "execution_identity_digest", dg("execution_identity_digest", "GH700:execution-identity:v1", body["time_bound_intent"]["execution_identity"]), method)
    if "control_operation_id" in body:
        derive(body, "control_operation_id", op_id, method)
    if "broker_delivery_id" in body:
        derive(body, "broker_delivery_id", dg("release_broker_delivery_id", "GH700:release-broker-delivery-id:v1", {"repo_node_id": request["repo_node_id"], "planned_operation_id": body["planned_operation_id"]}), method)
    if "generated_pr_delivery_id" in body:
        derive(body, "generated_pr_delivery_id", dg("generated_pr_delivery_id", "GH700:generated-pr-delivery-id:v1", {"repo_node_id": request["repo_node_id"], "planned_operation_id": body["planned_operation_id"]}), method)
    if "attempt_subject" in body:
        # The caller's key is only a byte-equal assertion over the
        # authority-derived subject, so it is recomputed from the closed
        # payload rather than trusted as an authority input.
        derive(body, "expected_attempt_subject_key", dg(
            "attempt_subject_key", "GH700:attempt-subject:v1", body["attempt_subject"],
        ), method)
    if "recovery_query_digest" in body:
        derive(body, "recovery_query_digest", dg("recovery_query_digest", "GH700:recovery-query:v1", {"method": method, "planned_operation_id": body["planned_operation_id"]}), method)
    if "capsule_source" in body:
        source = body["capsule_source"]
        derive(source, "source_request_id", dg("capsule_source_request_id", "GH700:capsule-source-request-id:v1", {key: source[key] for key in ("source_method", "source_operation_id", "secret_slot_id")}), method)
    derive_authorization_fields(body, op_id, method, derive, dg)
    for key in AUTH_KEYS:
        auth = body.get(key)
        if isinstance(auth, dict):
            auth_digest(auth, f"{method}.{key}")
    channel = body.get("secret_channel_binding")
    if isinstance(channel, dict):
        core_body = {key: item for key, item in body.items() if key != "secret_channel_binding"}
        core = {key: item for key, item in request.items() if key not in {"operation_request_digest", "body"}}
        core["body"] = core_body
        derive(channel, "secret_channel_request_core_digest", dg(
            "secret_channel_request_core_digest", "GH700:secret-channel-request-core:v1", core,
        ), method)
        exporter_context = {key: channel[key] for key in (
            "authority_id", "repo_node_id", "method", "secret_channel_request_core_digest",
            "peer_identity_digest", "server_identity_digest", "secret_slot_ids",
        )}
        derive(channel, "tls_exporter_context_digest", dg(
            "tls_exporter_context_digest", "GH700:tls-exporter-context:v1", exporter_context,
        ), method)
        keying = decode_b64u(channel["tls_exporter_keying_material_b64u"], 32, f"{method}.tls_exporter")
        require_domain(DIGEST_SCHEMA, "tls_exporter_keying_material_digest", None, ContractError)
        derive(channel, "tls_exporter_keying_material_digest", sha(keying), method)
        derive(channel, "secret_channel_binding_digest", dg(
            "secret_channel_binding_digest", "GH700:secret-channel-binding-digest:v1",
            {key: item for key, item in channel.items() if key != "secret_channel_binding_digest"},
        ), method)
    derive(request, "operation_request_digest", dg("operation_request_digest", f"GH700:{surface}-operation-request:v1", {key: item for key, item in request.items() if key != "operation_request_digest"}, context=surface), method)
    nonce_digest = dg(f"{surface}_request_nonce_digest", f"GH700:{surface}-request-nonce:v1", {"authority_id": request["authority_id"], "repo_node_id": request["repo_node_id"], "authenticated_principal_digest": request["authenticated_principal_digest"], "request_nonce": b64u(nonce)})
    return op_id, nonce_digest


def response_digests(response, request, surface, op_id, nonce_digest):
    method = request["method"]
    if BINDING_MATRIX is not None:
        validate_common_bindings(request, response, BINDING_MATRIX, ContractError)
    if response["method"] != method or response["operation_request_digest"] != request["operation_request_digest"]:
        raise ContractError(f"{method}: response request binding mismatch")
    derive(response, f"{surface}_request_nonce_digest", nonce_digest, method)
    response_nonce = decode_b64u(response["response_nonce"], 32, f"{method}.response_nonce")
    if "result" in response:
        # Formula-owned identifiers are only substituted into the positive
        # fixtures. A caller-supplied literal has to be recomputed here, or a
        # response can name a delivery the request never planned.
        if "generated_pr_delivery_id" in response["result"]:
            derive(response["result"], "generated_pr_delivery_id", dg(
                "generated_pr_delivery_id", "GH700:generated-pr-delivery-id:v1",
                {"repo_node_id": request["repo_node_id"], "planned_operation_id": op_id},
            ), method)
        bind_nested_receipts(response["result"], request, op_id, ContractError, derive, dg, f"{method}.result")
        validate_nested_capsules(response["result"], KMS_MANIFEST, derive, dg, ContractError)
        receipt_digests(response["result"])
        derive(response, "result_digest", dg("result_digest", f"GH700:{surface}-result:v1", response["result"], context=surface), method)
    preimage = {key: item for key, item in response.items() if key != "response_digest"}
    preimage["response_nonce_digest"] = dg("response_nonce_digest", f"GH700:{surface}-response-nonce:v1", {"response_nonce": b64u(response_nonce)}, context=surface)
    derive(response, "response_digest", dg("response_digest", f"GH700:{surface}-response:v1", preimage, context=surface), method)


def materialize(model, fixtures):
    request = {**expand({"$fixture": model["request_base"]}, fixtures), **expand(model["request_patch"], fixtures)}
    op_id, nonce_digest = request_digests(request, model["surface"])
    channel = request["body"].get("secret_channel_binding", {})
    values = {"method": request["method"], "operation_id": op_id, "operation_request_digest": request["operation_request_digest"], "generated_pr_delivery_id": dg("generated_pr_delivery_id", "GH700:generated-pr-delivery-id:v1", {"repo_node_id": request["repo_node_id"], "planned_operation_id": op_id}), "publication_frontier": request.get("expected_publication_frontier_or_null"), "blocked_frontier": request.get("expected_blocked_attempt_frontier_or_null"), "secret_channel_binding_digest": channel.get("secret_channel_binding_digest"), "release_identity_attestation_digest": request["body"].get("release_identity_attestation", {}).get("attestation_digest")}
    response = context({**expand({"$fixture": model["success_base"]}, fixtures), **expand(model["success_patch"], fixtures)}, values)
    response_digests(response, request, model["surface"], op_id, nonce_digest)
    if any(isinstance(item, dict) and ({"$derive", "$context"} & set(item)) for item in walk((request, response))):
        raise ContractError(f"{model['model_id']}: unresolved directive")
    return request, response


def check_scalars(schema):
    defs = schema["$defs"]
    if defs["nonce"].get("pattern") != r"^[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$":
        raise ContractError("nonce schema final character is not canonical")
    for raw in (bytes(32), b"\xff" * 32, bytes(range(32))):
        decode_b64u(b64u(raw), 32, "nonce positive")
    for bad in ("A" * 42 + "B", "A" * 43 + "=", "A" * 42):
        try:
            decode_b64u(bad, 32, "nonce negative")
        except ContractError:
            pass
        else:
            raise ContractError(f"bad nonce accepted: {bad}")
    if defs["signature_b64u"].get("pattern") != r"^[A-Za-z0-9_-]{85}[AQgw]$":
        raise ContractError("signature schema final character is not canonical")
    decode_b64u(b64u(bytes(range(64))), 64, "signature positive")
    if defs["uint64"]["oneOf"][1]["pattern"] != r"^(0|[1-9][0-9]*)$":
        raise ContractError("uint64 string pattern is not syntax-only canonical decimal")
    good = (0, SAFE_MAX, str(SAFE_MAX + 1), "10000000000000000", str(U64_MAX))
    if [uint64(item, "uint64 positive") for item in good] != [0, SAFE_MAX, SAFE_MAX + 1, 10**16, U64_MAX]:
        raise ContractError("uint64 positive boundaries failed")
    for bad in (-1, SAFE_MAX + 1, "00", "01", str(SAFE_MAX), str(U64_MAX + 1)):
        try:
            uint64(bad, "uint64 negative")
        except ContractError:
            pass
        else:
            raise ContractError(f"bad uint64 accepted: {bad}")


def check_schema(schema, root):
    global DIGEST_SCHEMA; DIGEST_SCHEMA = schema
    if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
        raise ContractError("Draft 2020-12 declaration missing")
    refs = []
    for item in walk(schema):
        if isinstance(item, dict) and "$ref" in item:
            refs.append(item["$ref"])
            pointer(schema, item["$ref"])
    check_scalars(schema)
    defs = schema["$defs"]
    if any(item.get("x-gh700-semantic-validator") != "uint64" for item in walk(schema) if isinstance(item, dict) and "x-gh700-semantic-validator" in item): raise ContractError("unknown semantic validator in schema")
    if defs["uint64"].get("x-gh700-semantic-validator") != "uint64":
        raise ContractError("uint64 semantic validator binding missing")
    unevaluated_count = sum(
        item.get("unevaluatedProperties") is False
        for item in walk(schema)
        if isinstance(item, dict)
    )
    if unevaluated_count == 0:
        raise ContractError("closed allOf wire schemas missing unevaluatedProperties")
    methods = {"client": CLIENT, "control": CONTROL}
    for name, surface in (("client_request_envelope", "client"), ("client_success_envelope", "client"), ("control_request_envelope", "control"), ("control_success_envelope", "control")):
        if tuple(defs[name]["properties"]["method"].get("enum", ())) != methods[surface]:
            raise ContractError(f"{name}: open or reordered method enum")
    for name, surface in (("client_api_replay_row", "client"), ("control_api_replay_row", "control")):
        if tuple(defs[name]["properties"]["method"].get("enum", ())) != methods[surface]:
            raise ContractError(f"{name}: missing closed method enum")
    for name in ("transition_receipt", "frontier_receipt", "control_receipt", "enumeration_snapshot_receipt"):
        if not 8 <= len(defs[name]["required"]) <= 11:
            raise ContractError(f"{name}: receipt must have 8-11 fields")
    if "receipt" in defs and len(defs["receipt"].get("required", ())) == 2:
        raise ContractError("generic two-field receipt remains")
    signing = {"signing_key_id", "signing_key_material_id", "signing_preimage_digest", "signature_b64u", "signature_digest"}
    signing_meta = schema.get("x-gh700-signing-preimages", {})
    # The four authorization branches are the exact schema-owned signing
    # registry. Reading only the expected names would let an extra branch reuse
    # an existing domain and still certify, so the registry is closed by set.
    if set(signing_meta) != set(SIGNING_BRANCHES):
        raise ContractError(f"signing preimage registry is not exactly {sorted(SIGNING_BRANCHES)}")
    for name in SIGNING_BRANCHES:
        if not signing <= set(defs[name]["required"]):
            raise ContractError(f"{name}: incomplete signing contract")
        meta = signing_meta.get(name, {})
        expected_fields = [field for field in defs[name]["required"] if field not in {"signing_preimage_digest", "signature_b64u", "signature_digest"}]
        if meta.get("domain") != defs[name]["properties"]["schema_version"]["const"].replace(":v1", ":signing-preimage:v1") or meta.get("preimage_fields") != expected_fields or "manifest-pinned" not in meta.get("key_binding", ""):
            raise ContractError(f"{name}: signing preimage/key metadata mismatch")
    material_schema = defs["authority_capsule_key_attestation"]["properties"]["kms_key_material_id"]
    if material_schema.get("$ref"):
        material_schema = pointer(schema, material_schema["$ref"])
    if material_schema.get("pattern") != "^[0-9a-f]{64}$":
        raise ContractError("KeyMaterialId is not exact 64hex")
    if "selector" not in defs["control_body_recover"]["required"]:
        raise ContractError("control recovery selector missing")
    deployment = defs["deployment_manifest"]
    if deployment["properties"].get("deployment_policy") != {"$ref": "#/$defs/deployment_policy_binding"} or any(item.get("$ref") == "#/$defs/prebootstrap_policy_binding" for item in walk(deployment) if isinstance(item, dict)):
        raise ContractError("history deployment manifest policy branch is not deployment-only")
    owners = {"authorization": "#/$defs/authorization", "receipt": "#/$defs/typed_receipt", "digest": "#/x-gh700-digest-formulas", "replay": "#/$defs/replay_row", "kms": "#/$defs/authority_kms_manifest"}
    if schema.get("x-gh700-wire-owners") != owners or len(set(owners.values())) != 5:
        raise ContractError("wire owner map mismatch")
    for ref in owners.values():
        pointer(schema, ref)
    forbidden = set(schema["x-gh700-forbidden-aliases"])
    for name, definition in defs.items():
        if name in forbidden:
            raise ContractError(f"forbidden alias definition: {name}")
        for item in walk(definition):
            if isinstance(item, dict) and (forbidden & (set(item.get("required", ())) | set(item.get("properties", {})))):
                raise ContractError(f"forbidden alias field in {name}")
    compact = "".join((root / name).read_text(encoding="utf-8").replace(" ", "") for name in ("publication_history_contract.md", "publication_ledger_contract.md", "publication_authority_protocol_contract.md"))
    for marker in ('"schema_version":"GH700:append-authorization:v1"', '"schema_version":"GH700:delivery-authorization:v1"', '"schema_version":"GH700:ledger-append-authorization:v1"', '"receipt_version":"GH700:'):
        if marker in compact:
            raise ContractError(f"duplicate prose wire owner: {marker}")
    return len(refs), unevaluated_count


def check_dag(schema):
    dag, formulas = schema["x-gh700-digest-dag"], schema["x-gh700-digest-formulas"]
    nodes = dag["nodes"]
    if schema.get("x-gh700-digest-framing") != "digest = lowercase sha256:<64hex> of SHA256(JCS({v:domain,...preimage_fields})); callers may not supply v":
        raise ContractError("digest framing mismatch")
    if len(nodes) != len(set(nodes)) or set(nodes) != set(formulas) or set(nodes) != REQUIRED_DIGEST_NODES:
        raise ContractError("digest formula/DAG node mismatch")
    validate_domain_sets(schema, ContractError)
    for name, formula in formulas.items():
        if set(formula) != {"domain", "preimage", "wire_consumers"} or not all(formula.values()):
            raise ContractError(f"incomplete digest formula: {name}")
    outgoing, indegree = {node: [] for node in nodes}, {node: 0 for node in nodes}
    for source, target in dag["edges"]:
        if source not in outgoing or target not in outgoing or source == target:
            raise ContractError("invalid digest DAG edge")
        outgoing[source].append(target); indegree[target] += 1
    queue, seen = [node for node in nodes if indegree[node] == 0], 0
    while queue:
        node = queue.pop(0); seen += 1
        for target in outgoing[node]:
            indegree[target] -= 1
            if indegree[target] == 0: queue.append(target)
    if seen != len(nodes):
        raise ContractError("digest DAG cycle")
    return len(nodes), len(dag["edges"])


def semantic_pair(request, response, model):
    method = model["method"]
    if request["method"] != method or response["method"] != method:
        raise ContractError(f"{model['model_id']}: method mismatch")
    if method == "recover_generated_pr":
        result = response["result"]
        if len(result["transition_receipts"]) != (2 if result["recovery_state"] == "merged_existing" else 1):
            raise ContractError("recover_generated_pr receipt cardinality")
        expected = {"bound_existing": ["generated_pr_bound"], "merged_existing": ["generated_pr_bound", "generated_pr_merged"], "not_applied": ["generated_pr_not_applied"], "blocked": ["generated_pr_blocked"]}[result["recovery_state"]]
        if [receipt["receipt_kind"] for receipt in result["transition_receipts"]] != expected:
            raise ContractError("recover_generated_pr receipt sequence")
    if method == "recover" and request["body"]["selector"] not in {"database", "backup", "anchor"}:
        raise ContractError("unknown recovery selector")


def verify_pair(request, response, model, registry_row, schema):
    if (model["surface"], model["method"]) != (registry_row["surface"], registry_row["method"]):
        raise ContractError(f"{model['model_id']}: registry row mismatch")
    validate(request, pointer(schema, registry_row["request_ref"]), schema)
    validate(response, pointer(schema, registry_row["success_ref"]), schema)
    validate(request, schema, schema)
    validate(response, schema, schema)
    validate_pair_bindings(request, response, BINDING_MATRIX, registry_row, model["model_id"], ContractError)
    semantic_pair(request, response, model)
    checked_request = copy.deepcopy(request)
    op_id, nonce_digest = request_digests(checked_request, model["surface"])
    checked_response = copy.deepcopy(response)
    response_digests(
        checked_response, checked_request, model["surface"], op_id, nonce_digest
    )


def expect_pair_rejected(label, request, response, model, registry_row, schema):
    if any(marker in label for marker in (".missing_", ".null_", ".extra", ".wrong_method", ".forbidden_alias", ".error_result_collision")):
        try:
            validate(request, pointer(schema, registry_row["request_ref"]), schema)
            validate(response, pointer(schema, registry_row["success_ref"]), schema)
        except ContractError:
            return
        raise ContractError(f"structural positive mutation accepted: {label}")
    try:
        verify_pair(request, response, model, registry_row, schema)
    except ContractError:
        return
    raise ContractError(f"positive mutation accepted: {label}")


def applicable_semantic_paths(value, schema, root, path=()):
    paths = set()
    if not isinstance(schema, dict):
        return paths
    if schema.get("x-gh700-semantic-validator") == "uint64":
        paths.add(path)
    if "$ref" in schema:
        paths.update(applicable_semantic_paths(value, pointer(root, schema["$ref"]), root, path))
    for child in schema.get("allOf", ()):
        paths.update(applicable_semantic_paths(value, child, root, path))
    for keyword in ("anyOf", "oneOf"):
        for child in schema.get(keyword, ()):
            if valid(value, child, root):
                paths.update(applicable_semantic_paths(value, child, root, path))
    if "if" in schema:
        branch = schema.get("then") if valid(value, schema["if"], root) else schema.get("else")
        if branch is not None:
            paths.update(applicable_semantic_paths(value, branch, root, path))
    if isinstance(value, dict):
        for key, child in schema.get("properties", {}).items():
            if key in value:
                paths.update(applicable_semantic_paths(value[key], child, root, path + (key,)))
    if isinstance(value, list) and "items" in schema:
        for index, item in enumerate(value):
            paths.update(applicable_semantic_paths(item, schema["items"], root, path + (index,)))
    return paths


def replace_path(value, path, replacement):
    target = value
    for step in path[:-1]:
        target = target[step]
    target[path[-1]] = replacement


def mutate_binding_value(value, kind):
    if kind == "digest": return "sha256:" + ("e" if value != "sha256:" + "e" * 64 else "f") * 64
    if kind == "id": return f"{value}-mutation"
    if kind == "uint64": return uint64(value, kind) + 1
    if kind == "frontier":
        mutated = copy.deepcopy(value); mutated["full_prefix_digest"] = "sha256:" + "e" * 64; return mutated
    if kind == "policy":
        mutated = copy.deepcopy(value); key = "policy_bundle_digest" if "policy_bundle_digest" in mutated else "projection_digest"; mutated[key] = "sha256:" + "e" * 64; return mutated
    if kind == "slots": return ["mutation_nonce"] if value != ["mutation_nonce"] else ["draft_claim_nonce"]
    if kind in {"method", "state", "receipt_kind"}: return f"{value}_mutation"
    if kind == "nullability": return {"mutation": True}
    raise ContractError(f"unknown binding mutation kind: {kind}")


def check_uint64_instance_mutations(pairs, models, registry_by_method, schema):
    count = 0
    for model in models:
        row = registry_by_method[(model["surface"], model["method"])]
        request, response = pairs[model["model_id"]]
        for side, value, schema_ref in (
            ("request", request, row["request_ref"]),
            ("response", response, row["success_ref"]),
        ):
            for path in applicable_semantic_paths(value, pointer(schema, schema_ref), schema):
                mutated_request, mutated_response = copy.deepcopy((request, response))
                replace_path(mutated_request if side == "request" else mutated_response, path, str(U64_MAX + 1))
                expect_pair_rejected(
                    f"{model['model_id']}.{side}.{'.'.join(map(str, path))}.uint64_overflow",
                    mutated_request, mutated_response, model, row, schema,
                )
                count += 1
    if count == 0:
        raise ContractError("no materialized uint64 instances were mutation-tested")
    return count


def check_digest_node_mutations(schema):
    count = 0
    validate_domain_sets(schema, ContractError)
    for node in schema["x-gh700-digest-dag"]["nodes"]:
        original = schema["x-gh700-digest-formulas"][node]["domain"]
        for kind, replacement in (("added", original + f" or GH700:mutation-added:{node}:v1"), ("removed", ""), ("replaced", f"GH700:mutation-replaced:{node}:v1")):
            mutated = copy.deepcopy(schema)
            mutated["x-gh700-digest-formulas"][node]["domain"] = replacement
            try:
                validate_domain_sets(mutated, ContractError)
            except ContractError:
                count += 1
                continue
            raise ContractError(f"digest node {kind} mutation accepted: {node}")
    if count != 3 * len(REQUIRED_DIGEST_NODES):
        raise ContractError("digest mutation matrix is incomplete")
    return count


def negative(case, pairs, schema):
    kind = case["mutation"]
    scalar_bad = {"nonce_padding": lambda: decode_b64u("A" * 43 + "=", 32, kind), "nonce_noncanonical_last_char": lambda: decode_b64u("A" * 42 + "B", 32, kind), "uint64_leading_zero": lambda: uint64("01", kind), "uint64_overflow": lambda: uint64(str(U64_MAX + 1), kind)}
    try:
        if kind in scalar_bad:
            scalar_bad[kind](); return False
        request, response = copy.deepcopy(pairs[case["model_id"]])
        if kind == "unknown_method":
            request["method"] = "unknown_method"; validate(request, schema, schema)
        elif kind == "operation_request_digest_mismatch":
            request["operation_request_digest"] = "sha256:" + "f" * 64; request_digests(request, case["surface"])
        elif kind in {"result_digest_mismatch", "response_digest_mismatch"}:
            response["result_digest" if kind.startswith("result") else "response_digest"] = "sha256:" + "f" * 64
            op, nonce = request_digests(request, case["surface"]); response_digests(response, request, case["surface"], op, nonce)
        elif kind == "authorization_method_mismatch":
            key = next(key for key in AUTH_KEYS if key in request["body"]); request["body"][key]["authorized_method"] = "ready"; request_digests(request, case["surface"])
        elif kind == "authorization_frontier_mismatch":
            key = next(key for key in ("append_authorization", "ledger_append_authorization") if key in request["body"]); request["body"][key]["authorized_predecessor_frontier"]["full_prefix_digest"] = "sha256:" + "f" * 64; request_digests(request, case["surface"])
        elif kind == "receipt_extra_field":
            target = next(item for item in walk(response["result"]) if isinstance(item, dict) and "receipt_digest" in item); target["invented"] = True; validate(response, schema, schema)
        elif kind == "merged_existing_one_receipt":
            response["result"]["transition_receipts"] = response["result"]["transition_receipts"][:1]; validate(response, schema, schema)
        elif kind == "unknown_recovery_selector":
            request["body"]["selector"] = "filesystem"; validate(request, schema, schema)
        elif kind == "capsule_source_branch_mismatch":
            request["body"]["capsule_source"]["secret_slot_id"] = "mutation_nonce"; validate(request, schema, schema)
        elif kind == "ready_not_found_error":
            validate(expand(case["value"], case["fixtures"]), schema, schema)
        else:
            raise ContractError(f"unknown negative mutation: {kind}")
    except ContractError:
        return True
    return False


def main():
    parser = argparse.ArgumentParser(); parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent); parser.add_argument("--emit-materialized", type=Path); args = parser.parse_args()
    global BINDING_MATRIX, KMS_MANIFEST, SIGNING_MANIFEST
    root = args.root.resolve(); schema = load(root / "publication_authority_api.schema.json"); models = load(root / "publication_authority_api.models.json")
    refs, unevaluated = check_schema(schema, root); dag_nodes, dag_edges = check_dag(schema); digest_mutations = check_digest_node_mutations(schema)
    anchors = check_registry_anchors(schema, jcs, ContractError)
    anchor_mutations = check_registry_anchor_mutations(schema, jcs, ContractError)
    SIGNING_MANIFEST = expand({"$fixture": "authority_signing_manifest"}, models["fixtures"])
    validate(SIGNING_MANIFEST, pointer(schema, "#/$defs/authority_signing_manifest"), schema)
    KMS_MANIFEST, kms_digests = materialize_kms_manifest(schema, models["fixtures"], expand, validate, pointer, derive, dg, ContractError)
    expected_rows = [("client", method) for method in CLIENT] + [("control", method) for method in CONTROL]
    BINDING_MATRIX = validate_binding_matrix(
        schema, models["models"], expected_rows, pointer, ContractError,
    )
    matrix_mutations = check_binding_matrix_mutations(schema, models["models"], expected_rows, pointer, ContractError)
    contextual_domain_mutations = check_contextual_domain_rejections(schema, ContractError)
    registry = BINDING_MATRIX["rows"]
    error_sets = {row["method"]: set(row["error_codes"]) for row in registry if row["surface"] == "control"}
    if "not_found" not in error_sets["recover"] or "not_found" in error_sets["ready"]:
        raise ContractError("control not_found registry partition mismatch")
    error_branches = check_error_branches(schema, registry, {"client": CLIENT, "control": CONTROL}, validate, pointer, ContractError)
    registry_by_method = {(row["surface"], row["method"]): row for row in registry}
    pairs, coverage, digest_count = {}, set(), 0
    for model in models["models"]:
        request, response = materialize(model, models["fixtures"])
        row = row_for_model(BINDING_MATRIX, model, ContractError)
        verify_pair(request, response, model, row, schema)
        pairs[model["model_id"]] = (request, response); coverage.update(model.get("coverage_tags", ()))
        digests = [item for item in walk((request, response)) if isinstance(item, str) and item.startswith("sha256:")]
        if not digests or "sha256:" + "0" * 64 in digests: raise ContractError(f"{model['model_id']}: missing/zero digest")
        digest_count += len(digests)
    if len(models["models"]) < 22: raise ContractError("fewer than 22 positive models")
    positive_mutations = 0
    for model in models["models"]:
        row = row_for_model(BINDING_MATRIX, model, ContractError)
        request, response = pairs[model["model_id"]]
        for label, bad_request, bad_response in relation_mutations(
            request, response, BINDING_MATRIX, row, model["model_id"], mutate_binding_value, ContractError,
        ):
            try:
                validate_pair_bindings(bad_request, bad_response, BINDING_MATRIX, row, model["model_id"], ContractError)
            except ContractError:
                positive_mutations += 1
            else:
                raise ContractError(f"binding mutation accepted: {label}")
    row_fields = check_row_contract_fields(schema, registry, pairs, pointer, validate, ContractError)
    profile_selectors = check_profile_selectors(registry, pairs, ContractError)
    structural_mutations = check_structural_mutations(
        pairs, models["models"], registry_by_method, schema, {"client": CLIENT, "control": CONTROL},
        validate, pointer, ContractError,
    )
    kms_mutations = check_nested_kms_mutations(pairs, KMS_MANIFEST, derive, dg, ContractError)
    uint64_mutations = check_uint64_instance_mutations(pairs, models["models"], registry_by_method, schema)
    auxiliary = models.get("auxiliary_positive_instances", ())
    for item in auxiliary:
        value = expand(item["value"], models["fixtures"])
        if item["schema_ref"].endswith("replay_row"):
            surface = "client" if "client_" in item["schema_ref"] else "control"
            nonce = decode_b64u(value["request_nonce"], 32, item["model_id"])
            nonce_digest = dg(f"{surface}_request_nonce_digest", f"GH700:{surface}-request-nonce:v1", {"authority_id": value["authority_id"], "repo_node_id": value["repo_node_id"], "authenticated_principal_digest": value["authenticated_principal_digest"], "request_nonce": b64u(nonce)})
            derive(value, f"{surface}_request_nonce_digest", nonce_digest, item["model_id"])
            derive(value, "replay_row_digest", dg("replay_row_digest", "GH700:api-replay-row:v1", {key: child for key, child in value.items() if key != "replay_row_digest"}), item["model_id"])
        validate(value, pointer(schema, item["schema_ref"]), schema); coverage.update(item.get("coverage_tags", ()))
    errors = models.get("error_models", ())
    for item in errors:
        request = pairs[item["request_model_id"]][0]
        surface = "client" if request["api_version"] == "GH700:client-api:v1" else "control"
        op_id, nonce_digest = request_digests(copy.deepcopy(request), surface)
        value = context(expand(item["value"], models["fixtures"]), {"operation_request_digest": request["operation_request_digest"]})
        response_digests(value, request, surface, op_id, nonce_digest)
        validate(value, schema, schema); coverage.update(item.get("coverage_tags", ()))
    missing = COVERAGE - coverage
    if missing: raise ContractError(f"missing positive coverage: {sorted(missing)}")
    negatives = models.get("negative_fixtures", ())
    for case in negatives:
        case = {**case, "fixtures": models["fixtures"]}
        if not negative(case, pairs, schema): raise ContractError(f"negative accepted: {case['fixture_id']}")
    if args.emit_materialized:
        args.emit_materialized.mkdir(parents=True, exist_ok=True)
        for model_id, (request, response) in pairs.items():
            (args.emit_materialized / f"{model_id}.request.json").write_bytes(jcs(request)); (args.emit_materialized / f"{model_id}.response.json").write_bytes(jcs(response))
    print(f"PUBLICATION_AUTHORITY_API_OK registry=17+5 models={len(models['models'])} auxiliary={len(auxiliary)} errors={len(errors)} refs={refs} unevaluated={unevaluated} digests={digest_count}+{kms_digests}kms mismatches=0 dag={dag_nodes}/{dag_edges} positive_mutations={positive_mutations} matrix_mutations={matrix_mutations} contextual_domain_mutations={contextual_domain_mutations} kms_mutations={kms_mutations} uint64_mutations={uint64_mutations} digest_mutations={digest_mutations} negatives={len(negatives)} coverage={len(coverage)} row_fields={row_fields} profile_selectors={profile_selectors} structural_mutations={structural_mutations} anchors={anchors}/{anchor_mutations} error_branches={error_branches}")


if __name__ == "__main__":
    try:
        main()
    except ContractError as exc:
        print(f"PUBLICATION_AUTHORITY_API_FAIL {exc}", file=sys.stderr); raise SystemExit(1)

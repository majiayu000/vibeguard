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
from publication_authority_semantic_contracts import PublicationAuthoritySemanticContracts
from publication_digest_domains import check_contextual_domain_rejections, require_domain
from publication_schema_validator import make_validator
from publication_signature_contract import self_test as signature_self_test
from publication_signature_contract import verify_or_materialize
from publication_structural_mutations import check_structural_mutations
from publication_wire_registries import anchor_digest, check_error_branches, check_registry_anchor_mutations, check_registry_anchors
from publication_typed_contracts import (
    bind_nested_receipts, check_nested_kms_mutations, materialize_kms_manifest, validate_nested_capsules,
)

SAFE_MAX = 9_007_199_254_740_991
U64_MAX = 18_446_744_073_709_551_615
CLIENT = ("get_publication_head", "claim_publication_owner", "renew_publication_owner", "takeover_publication_owner", "append_publication_transition", "plan_release_mutation", "deliver_release_mutation", "recover_release_mutation", "plan_generated_pr", "deliver_generated_pr", "recover_generated_pr", "append_blocked_attempt", "bind_blocked_attempt", "list_blocked_attempts", "commit_reconciliation_watermark", "get_blocked_attempt_frontier", "read_secret_capsule")
CONTROL = ("prepare_bootstrap_trusted_time", "bootstrap", "migrate", "recover", "ready")
EXPECTED_MODEL_IDS = (
    "client.get_publication_head", "client.claim_publication_owner", "client.renew_publication_owner",
    "client.takeover_publication_owner", "client.append_publication_transition", "client.plan_release_mutation",
    "client.deliver_release_mutation", "client.deliver_release_mutation.recovery_pending",
    "client.recover_release_mutation", "client.plan_generated_pr", "client.deliver_generated_pr",
    "client.recover_generated_pr", "client.append_blocked_attempt", "client.bind_blocked_attempt",
    "client.list_blocked_attempts", "client.commit_reconciliation_watermark",
    "client.get_blocked_attempt_frontier", "client.read_secret_capsule",
    "control.prepare_bootstrap_trusted_time", "control.bootstrap", "control.migrate", "control.recover",
    "control.ready", "client.bind_blocked_attempt.source_snapshot",
    "client.recover_generated_pr.merged_existing", "control.recover.backup", "control.recover.anchor",
    "client.recover_release_mutation.recovery_pending", "client.recover_release_mutation.not_applied",
    "client.recover_release_mutation.compensated", "client.recover_release_mutation.blocked",
    "client.recover_generated_pr.not_applied", "client.recover_generated_pr.blocked",
    "client.deliver_generated_pr.recovery_required", "client.read_secret_capsule.claim",
)
COVERAGE = {"source_binding", "genesis", "key_attestation", "client_replay", "control_replay", "terminal_binding", "snapshot_binding", "merged_existing_receipts", "recover_selector_database", "recover_selector_backup", "recover_selector_anchor", "control_not_found", "prebootstrap_policy", "release_recovery_pending", "release_not_applied", "release_compensated", "release_blocked", "generated_pr_not_applied", "generated_pr_blocked", "delivery_recovery_required", "capsule_source_plan", "capsule_source_claim"}
DIGEST_SCHEMA = None
KMS_MANIFEST = None
BINDING_MATRIX = None
SEMANTICS = None


class ContractError(Exception):
    pass


def pairs_no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ContractError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def parse_contract_json(raw, label):
    def reject_nonfinite(value):
        raise ContractError(f"{label}: non-finite JSON number forbidden: {value}")
    return json.loads(
        raw, object_pairs_hook=pairs_no_duplicates, parse_constant=reject_nonfinite,
    )


def load(path):
    try:
        value = parse_contract_json(path.read_text(encoding="utf-8"), path)
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
    # is a byte-equal restatement of the subject inside the submitted record.
    omitted = set(AUTH_KEYS) | {"time_bound_request_id", "control_operation_id", "broker_delivery_id", "generated_pr_delivery_id", "recovery_query_digest", "secret_channel_binding", "expected_attempt_subject_key"}
    return {key: strip_ids(item) for key, item in value.items() if key not in omitted}


def operation_id(request, surface):
    return dg("operation_id", "GH700:operation-id:v1", {
        "surface": surface, "method": request["method"], "authority_id": request["authority_id"], "repo_node_id": request["repo_node_id"],
        "expected_publication_frontier_or_null": request.get("expected_publication_frontier_or_null"),
        "expected_blocked_attempt_frontier_or_null": request.get("expected_blocked_attempt_frontier_or_null"), "subject": strip_ids(request["body"]),
    })


SIGNING_MANIFEST = None


def auth_digest(auth, label):
    preimage = {key: item for key, item in auth.items() if key not in {"signing_preimage_digest", "signature_b64u", "signature_digest"}}
    derive(auth, "signing_preimage_digest", dg(
        "authorization_signing_preimage_digest",
        auth["schema_version"].replace(":v1", ":signing-preimage:v1"), preimage,
        context=auth["schema_version"],
    ), label)
    require_domain(DIGEST_SCHEMA, "signature_digest", None, ContractError)
    verify_or_materialize(
        auth, auth["signing_preimage_digest"], label, "authorization",
        SIGNING_MANIFEST, decode_b64u, b64u, derive, sha, ContractError,
    )


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


def capsule_read_challenge_digest(request):
    challenge = request["body"].get("read_challenge")
    if challenge is None:
        return None
    require_domain(DIGEST_SCHEMA, "read_challenge_digest", None, ContractError)
    return sha(decode_b64u(challenge, 32, f"{request['method']}.read_challenge"))


def request_digests(request, surface):
    method, body = request["method"], request["body"]
    nonce = decode_b64u(request["request_nonce"], 32, f"{method}.request_nonce")
    if method == "prepare_bootstrap_trusted_time":
        derive(
            request["policy_binding"], "projection_digest",
            SEMANTICS.bootstrap_projection_digest(body["bootstrap_time_manifest_projection"]), method,
        )
    if "release_identity_attestation" in body:
        attestation = body["release_identity_attestation"]
        core = {
            key: item for key, item in attestation.items()
            if key not in {"attestation_digest", "signature_b64u", "signature_digest"}
        }
        derive(attestation, "attestation_digest", dg(
            "release_identity_attestation_digest",
            "GH700:release-identity-attestation:v1", core,
        ), method)
        require_domain(DIGEST_SCHEMA, "signature_digest", None, ContractError)
        verify_or_materialize(
            attestation, attestation["attestation_digest"], method, "release_identity",
            SIGNING_MANIFEST, decode_b64u, b64u, derive, sha, ContractError,
        )
        if uint64(attestation["valid_from_unix_seconds"], method) >= uint64(
            attestation["valid_until_unix_seconds"], method
        ):
            raise ContractError(f"{method}: release identity validity interval is empty")
    if "time_bound_intent" in body:
        # Derived before operation_id: the intent (policy digest included) binds
        # the operation, so both verification passes must see the same bytes.
        intent = body["time_bound_intent"]
        if intent["liveness_policy"] != SIGNING_MANIFEST["approved_liveness_policy"]:
            raise ContractError(f"{method}: liveness policy is not the manifest-approved H-006 policy")
        derive(intent["client_payload_core"], "liveness_policy_digest", dg(
            "liveness_policy_digest", "GH700:liveness-policy:v1", intent["liveness_policy"],
        ), method)
    record = body.get("attempt_record")
    if isinstance(record, dict) and "attempt_subject" in record:
        derive(record, "object_digest", dg(
            "blocked_attempt_object_digest", "GH700:blocked-attempt-record:v1",
            {key: item for key, item in record.items() if key != "object_digest"},
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
    if isinstance(record, dict) and "attempt_subject" in record:
        derive(body, "expected_attempt_subject_key", dg(
            "attempt_subject_key", "GH700:attempt-subject:v1",
            record["attempt_subject"],
        ), method)
    if "recovery_query_digest" in body:
        derive(body, "recovery_query_digest", dg("recovery_query_digest", "GH700:recovery-query:v1", {"method": method, "planned_operation_id": body["planned_operation_id"]}), method)
    if "capsule_source" in body:
        source = body["capsule_source"]
        derive(source, "source_request_id", dg(
            "capsule_source_request_id", "GH700:capsule-source-request-id:v1",
            {key: source[key] for key in (
                "source_method", "source_operation_id", "secret_slot_id",
                "issuance_secret_channel_binding_digest",
            )},
        ), method)
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


def response_digests(response, request, surface, op_id, nonce_digest, enumeration_records=None):
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
        bind_nested_receipts(
            response["result"], request, op_id, ContractError, derive, dg,
            f"{method}.result", capsule_read_challenge_digest(request),
        )
        validate_nested_capsules(response["result"], KMS_MANIFEST, derive, dg, ContractError)
        if method == "prepare_bootstrap_trusted_time":
            prepared = response["result"]
            receipt = prepared["prebootstrap_time_ceremony_receipt"]
            derive(
                receipt,
                "initial_time_proof_bundle_digest",
                sha(jcs(prepared["initial_time_proof_bundle"])),
                method,
            )
        if method == "list_blocked_attempts":
            listed = response["result"]
            receipt = listed["enumeration_snapshot_receipt"]
            if enumeration_records is None:
                if request["body"]["page_cursor_or_null"] is not None or listed["next_page_cursor_or_null"] is not None:
                    raise ContractError("list_blocked_attempts: multi-page response digest verification requires the accumulated full record set")
                enumeration_records = listed["attempt_records"]
            SEMANTICS.enumeration_receipt_digests(request, receipt, enumeration_records, method)
        receipt_digests(response["result"])
        derive(response, "result_digest", dg("result_digest", f"GH700:{surface}-result:v1", response["result"], context=surface), method)
    preimage = {key: item for key, item in response.items() if key != "response_digest"}
    preimage["response_nonce_digest"] = dg("response_nonce_digest", f"GH700:{surface}-response-nonce:v1", {"response_nonce": b64u(response_nonce)}, context=surface)
    derive(response, "response_digest", dg("response_digest", f"GH700:{surface}-response:v1", preimage, context=surface), method)


def materialize(model, fixtures, request_context=None):
    request = {**expand({"$fixture": model["request_base"]}, fixtures), **expand(model["request_patch"], fixtures)}
    if request_context is not None:
        request = context(request, request_context)
    op_id, nonce_digest = request_digests(request, model["surface"])
    channel = request["body"].get("secret_channel_binding", {})
    source = request["body"].get("capsule_source", {})
    values = {"method": request["method"], "operation_id": op_id, "source_operation_id": source.get("source_operation_id", op_id), "operation_request_digest": request["operation_request_digest"], "generated_pr_delivery_id": dg("generated_pr_delivery_id", "GH700:generated-pr-delivery-id:v1", {"repo_node_id": request["repo_node_id"], "planned_operation_id": op_id}), "publication_frontier": request.get("expected_publication_frontier_or_null"), "blocked_frontier": request.get("expected_blocked_attempt_frontier_or_null"), "source_request_id": source.get("source_request_id"), "read_challenge_digest": capsule_read_challenge_digest(request), "secret_channel_binding_digest": channel.get("secret_channel_binding_digest"), "issuance_secret_channel_binding_digest": source.get("issuance_secret_channel_binding_digest", channel.get("secret_channel_binding_digest")), "release_identity_attestation_digest": request["body"].get("release_identity_attestation", {}).get("attestation_digest")}
    if request["method"] == "prepare_bootstrap_trusted_time":
        values["prebootstrap_time_ceremony_id"] = prebootstrap_time_ceremony_id(request)
        values["projection_digest"] = request["policy_binding"]["projection_digest"]
        values["prebootstrap_time_approval_digest"] = request["policy_binding"]["prebootstrap_time_approval_digest"]
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


def prebootstrap_time_ceremony_id(request):
    return SEMANTICS.prebootstrap_time_ceremony_id(request)


def check_enumeration_pages(pages):
    return SEMANTICS.check_enumeration_pages(pages)


def check_enumeration_snapshot(request, response):
    return SEMANTICS.check_enumeration_pages(((request, response),))


def check_prebootstrap_ceremony(pairs):
    return SEMANTICS.check_prebootstrap_ceremony(pairs)


def check_cross_contract_mutations(pairs, schema):
    return SEMANTICS.check_cross_contract_mutations(pairs, schema)
def check_replay_state_mutations(auxiliary_values, schema):
    rejected = 0
    expected_states = {
        (surface, state)
        for surface in ("client", "control")
        for state in ("reserved", "effect_frozen", "response_frozen")
    }
    actual_states = set()
    for model_id, schema_ref, value in auxiliary_values:
        surface = "client" if "client_" in schema_ref else "control"
        actual_states.add((surface, value["replay_state"]))
        mutated = copy.deepcopy(value)
        mutated["response_digest_or_null"] = None if value["response_digest_or_null"] is not None else "sha256:" + "e" * 64
        try:
            validate(mutated, pointer(schema, schema_ref), schema)
        except ContractError:
            rejected += 1
        else:
            raise ContractError(f"{model_id}: replay state/nullability mutation accepted")
    if actual_states != expected_states:
        raise ContractError(f"replay state positive coverage mismatch: {sorted(actual_states)}")
    return rejected


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
    if method == "list_blocked_attempts":
        check_enumeration_snapshot(request, response)


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
    return SEMANTICS.check_digest_node_mutations(schema)
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
        elif kind in {"authorization_signature_mutation", "release_identity_signature_mutation"}:
            target = (request["body"]["release_identity_attestation"] if kind.startswith("release") else next(request["body"][key] for key in AUTH_KEYS if key in request["body"]))
            raw = decode_b64u(target["signature_b64u"], 64, kind)
            target["signature_b64u"] = b64u(bytes([raw[0] ^ 1]) + raw[1:])
            target["signature_digest"] = sha(decode_b64u(target["signature_b64u"], 64, kind))
            request_digests(request, case["surface"])
        elif kind == "liveness_policy_mutation":
            request["body"]["time_bound_intent"]["liveness_policy"]["ttl_seconds"] += 1; request_digests(request, case["surface"])
        elif kind == "attempt_subject_detached_mutation":
            record = request["body"]["attempt_record"]; record["attempt_subject"]["target_or_null"] = "other-target"
            request["body"]["expected_attempt_subject_key"] = dg("attempt_subject_key", "GH700:attempt-subject:v1", record["attempt_subject"]); request_digests(request, case["surface"])
        elif kind in {"capsule_issuance_operation_mismatch", "capsule_confirmation_source_mismatch", "capsule_challenge_mismatch"}:
            result = response["result"]
            if kind == "capsule_issuance_operation_mismatch": result["capsule_receipt"]["issuance_operation_id"] = "sha256:" + "f" * 64
            elif kind == "capsule_confirmation_source_mismatch": result["capsule_read_confirmation"]["source_request_id"] = "sha256:" + "f" * 64
            else: result["capsule_read_confirmation"]["read_challenge_digest"] = "sha256:" + "f" * 64
            op, nonce = request_digests(request, case["surface"]); response_digests(response, request, case["surface"], op, nonce)
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
    global BINDING_MATRIX, DIGEST_SCHEMA, KMS_MANIFEST, SEMANTICS, SIGNING_MANIFEST
    root = args.root.resolve(); schema = load(root / "publication_authority_api.schema.json"); models = load(root / "publication_authority_api.models.json")
    DIGEST_SCHEMA = schema
    SEMANTICS = PublicationAuthoritySemanticContracts({
        "error": ContractError, "get_signing_manifest": lambda: SIGNING_MANIFEST,
        "get_digest_schema": lambda: DIGEST_SCHEMA, "sha": sha, "jcs": jcs, "b64u": b64u,
        "decode_b64u": decode_b64u, "parse_json": parse_contract_json, "derive": derive,
        "walk": walk, "pointer": pointer, "check_scalars": check_scalars,
        "client_methods": CLIENT, "control_methods": CONTROL, "validate": validate,
        "request_digests": request_digests, "response_digests": response_digests,
    })
    refs, unevaluated = SEMANTICS.check_schema(schema, root); dag_nodes, dag_edges = SEMANTICS.check_dag(schema); digest_mutations = SEMANTICS.check_digest_node_mutations(schema)
    anchors = check_registry_anchors(schema, jcs, ContractError)
    anchor_mutations = check_registry_anchor_mutations(schema, jcs, ContractError)
    SIGNING_MANIFEST = expand({"$fixture": "authority_signing_manifest"}, models["fixtures"])
    validate(SIGNING_MANIFEST, pointer(schema, "#/$defs/authority_signing_manifest"), schema)
    signature_primitives = signature_self_test(ContractError)
    KMS_MANIFEST, kms_digests = materialize_kms_manifest(schema, models["fixtures"], expand, validate, pointer, derive, dg, ContractError)
    model_ids = tuple(model["model_id"] for model in models["models"])
    if model_ids != EXPECTED_MODEL_IDS:
        raise ContractError("positive model IDs do not match the pinned exact 35-model set")
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
        request_context = None
        if model["model_id"] == "control.bootstrap":
            prepared = pairs["control.prepare_bootstrap_trusted_time"][1]["result"]["prebootstrap_time_ceremony_receipt"]
            request_context = {
                "prebootstrap_time_ceremony_id": prepared["prebootstrap_time_ceremony_id"],
                "prebootstrap_time_ceremony_receipt_digest": prepared["receipt_digest"],
            }
        request, response = materialize(model, models["fixtures"], request_context)
        row = row_for_model(BINDING_MATRIX, model, ContractError)
        verify_pair(request, response, model, row, schema)
        pairs[model["model_id"]] = (request, response); coverage.update(model.get("coverage_tags", ()))
        digests = [item for item in walk((request, response)) if isinstance(item, str) and item.startswith("sha256:")]
        if not digests or "sha256:" + "0" * 64 in digests: raise ContractError(f"{model['model_id']}: missing/zero digest")
        digest_count += len(digests)
    check_prebootstrap_ceremony(pairs)
    cross_contract_mutations = check_cross_contract_mutations(pairs, schema)
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
    auxiliary_values = []
    for item in auxiliary:
        value = expand(item["value"], models["fixtures"])
        if item["schema_ref"].endswith("replay_row"):
            surface = "client" if "client_" in item["schema_ref"] else "control"
            nonce = decode_b64u(value["request_nonce"], 32, item["model_id"])
            nonce_digest = dg(f"{surface}_request_nonce_digest", f"GH700:{surface}-request-nonce:v1", {"authority_id": value["authority_id"], "repo_node_id": value["repo_node_id"], "authenticated_principal_digest": value["authenticated_principal_digest"], "request_nonce": b64u(nonce)})
            derive(value, f"{surface}_request_nonce_digest", nonce_digest, item["model_id"])
            derive(value, "replay_row_digest", dg("replay_row_digest", "GH700:api-replay-row:v1", {key: child for key, child in value.items() if key != "replay_row_digest"}), item["model_id"])
        validate(value, pointer(schema, item["schema_ref"]), schema); coverage.update(item.get("coverage_tags", ()))
        if item["schema_ref"].endswith("replay_row"):
            auxiliary_values.append((item["model_id"], item["schema_ref"], value))
    replay_mutations = check_replay_state_mutations(auxiliary_values, schema)
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
    print(f"PUBLICATION_AUTHORITY_API_OK registry=17+5 models={len(models['models'])} auxiliary={len(auxiliary)} errors={len(errors)} refs={refs} unevaluated={unevaluated} digests={digest_count}+{kms_digests}kms mismatches=0 dag={dag_nodes}/{dag_edges} positive_mutations={positive_mutations} matrix_mutations={matrix_mutations} contextual_domain_mutations={contextual_domain_mutations} kms_mutations={kms_mutations} uint64_mutations={uint64_mutations} digest_mutations={digest_mutations} negatives={len(negatives)} coverage={len(coverage)} row_fields={row_fields} profile_selectors={profile_selectors} structural_mutations={structural_mutations} cross_contract_mutations={cross_contract_mutations} replay_mutations={replay_mutations} anchors={anchors}/{anchor_mutations} error_branches={error_branches} signature_primitives={signature_primitives}")


if __name__ == "__main__":
    try:
        main()
    except ContractError as exc:
        print(f"PUBLICATION_AUTHORITY_API_FAIL {exc}", file=sys.stderr); raise SystemExit(1)

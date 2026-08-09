"""Typed-object semantic contracts selected by the GH700 binding matrix."""

import copy

# Every place the manifest key identity is copied into an attestation, tagged
# with which half it must equal. The mutation generator deliberately does NOT
# read this list — it rediscovers identity copies from the instance — so
# deleting a comparison here still leaves a mutation that must be caught.
ATTESTATION_IDENTITY_PATHS = (
    (("kms_key_arn",), "arn"),
    (("kms_key_material_id",), "material_id"),
    (("generate_data_key_request", "key_id"), "arn"),
    (("generate_data_key_response", "key_id"), "arn"),
    (("generate_data_key_response", "key_material_id"), "material_id"),
)


def _at(value, path):
    for step in path:
        value = value[step]
    return value


def validate_kms_attestation(attestation, manifest, derive, digest, error_type, label):
    request = attestation["generate_data_key_request"]
    response = attestation["generate_data_key_response"]
    identity = {"arn": manifest["kms_key_arn"], "material_id": manifest["kms_key_material_id"]}
    describe = manifest["describe_key_response"]
    if (describe["key_id"], describe["key_material_id"]) != (identity["arn"], identity["material_id"]):
        raise error_type(f"{label}: KMS manifest DescribeKey identity mismatch")
    for path, half in ATTESTATION_IDENTITY_PATHS:
        if _at(attestation, path) != identity[half]:
            raise error_type(f"{label}: KMS ARN/KeyMaterialId mismatch at {'.'.join(path)}")
    derive(attestation, "generate_data_key_request_digest", digest(
        "generate_data_key_request_digest", "GH700:generate-data-key-request:v1", request,
    ), label)
    derive(attestation, "key_material_attestation_digest", digest(
        "generate_data_key_material_attestation_digest",
        "GH700:generate-data-key-material-attestation:v1", response,
    ), label)
    if attestation["manifest_key_binding_digest"] != manifest["manifest_key_binding_digest"]:
        raise error_type(f"{label}: manifest binding mismatch")


def materialize_kms_manifest(schema, fixtures, expand, validate, pointer, derive, digest, error_type):
    manifest = expand({"$fixture": "authority_kms_manifest"}, fixtures)
    attestation = expand({"$fixture": "key_attestation"}, fixtures)
    validate(manifest, pointer(schema, "#/$defs/authority_kms_manifest"), schema)
    validate(attestation, pointer(schema, "#/$defs/authority_capsule_key_attestation"), schema)
    describe = manifest["describe_key_response"]
    derive(manifest, "key_material_attestation_digest", digest(
        "describe_key_material_attestation_digest", "GH700:describe-key-material-attestation:v1", describe,
    ), "KMS manifest")
    derive(manifest, "manifest_key_binding_digest", digest(
        "manifest_key_binding_digest", "GH700:authority-kms-manifest-key-binding:v1",
        {key: item for key, item in manifest.items() if key != "manifest_key_binding_digest"},
    ), "KMS manifest")
    validate_kms_attestation(attestation, manifest, derive, digest, error_type, "GenerateDataKey")
    return manifest, 4


def validate_nested_capsules(value, manifest, derive, digest, error_type, label="result"):
    count = 0
    if isinstance(value, list):
        return sum(validate_nested_capsules(item, manifest, derive, digest, error_type, f"{label}[{index}]") for index, item in enumerate(value))
    if not isinstance(value, dict):
        return 0
    for key, item in value.items():
        count += validate_nested_capsules(item, manifest, derive, digest, error_type, f"{label}.{key}")
    if "capsule_receipt_version" in value:
        validate_kms_attestation(value["key_attestation"], manifest, derive, digest, error_type, label)
        if (value["kms_key_arn"], value["kms_key_material_id"]) != (
            manifest["kms_key_arn"], manifest["kms_key_material_id"],
        ):
            raise error_type(f"{label}: capsule receipt KMS identity mismatch")
        count += 1
    return count


def check_nested_kms_mutations(pairs, manifest, derive, digest, error_type):
    count = 0
    for model_id, (_, response) in pairs.items():
        capsules = [item for item in _walk(response.get("result")) if isinstance(item, dict) and "capsule_receipt_version" in item]
        for index, capsule in enumerate(capsules):
            paths = [(("key_attestation", "manifest_key_binding_digest"), "digest")]
            paths += _identity_copies(capsule, manifest)
            for path, half in paths:
                mutated = copy.deepcopy(capsule)
                target = mutated
                for step in path[:-1]: target = target[step]
                replacement = {
                    "material_id": "f" * 64,
                    "digest": "sha256:" + "e" * 64,
                    "arn": "arn:aws:kms:us-east-1:111122223333:key/87654321-4321-4321-4321-cba987654321",
                }[half]
                target[path[-1]] = replacement
                # Recompute every digest the mutated field feeds, exactly as an
                # attacker who controls the request would. Without this the
                # digest derivation catches the mutation and the identity
                # comparisons are never actually exercised.
                _restamp_attestation_digests(mutated, digest)
                try:
                    validate_nested_capsules(mutated, manifest, derive, digest, error_type, model_id)
                except error_type:
                    count += 1
                else:
                    raise error_type(f"{model_id}: nested KMS mutation accepted at {'.'.join(path)}")
    return count


def _restamp_attestation_digests(capsule, digest):
    attestation = capsule.get("key_attestation")
    if not isinstance(attestation, dict):
        return
    attestation["generate_data_key_request_digest"] = digest(
        "generate_data_key_request_digest", "GH700:generate-data-key-request:v1",
        attestation["generate_data_key_request"],
    )
    attestation["key_material_attestation_digest"] = digest(
        "generate_data_key_material_attestation_digest",
        "GH700:generate-data-key-material-attestation:v1",
        attestation["generate_data_key_response"],
    )


def _identity_copies(value, manifest, path=()):
    """Rediscover every field carrying the manifest key identity.

    Derived from the instance rather than from ATTESTATION_IDENTITY_PATHS: a
    generator that reads the same list as the comparison loop cannot notice a
    comparison being deleted, because the deletion removes the probe too.
    """
    halves = {manifest["kms_key_arn"]: "arn", manifest["kms_key_material_id"]: "material_id"}
    found = []
    if isinstance(value, dict):
        for key, item in value.items():
            if isinstance(item, str) and item in halves:
                found.append((path + (key,), halves[item]))
            else:
                found.extend(_identity_copies(item, manifest, path + (key,)))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            found.extend(_identity_copies(item, manifest, path + (index,)))
    return found


def _walk(value):
    yield value
    children = value.values() if isinstance(value, dict) else value if isinstance(value, list) else ()
    for child in children:
        yield from _walk(child)


RECEIPT_REQUEST_BINDINGS = ("authority_id", "repo_node_id", "method")


def bind_nested_receipts(
    result, request, op_id, error_type, derive, digest, label="result",
    read_challenge_digest=None,
):
    """Bind every nested receipt to the request that produced it.

    The common response profile only proves the outer envelope, so a receipt
    could name another authority, repo, method, or operation while the envelope
    still matched and every digest recomputed cleanly.
    """
    bound = 0
    if isinstance(result, list):
        return sum(
            bind_nested_receipts(
                item, request, op_id, error_type, derive, digest,
                f"{label}[{index}]", read_challenge_digest,
            )
            for index, item in enumerate(result)
        )
    if not isinstance(result, dict):
        return 0
    for key, item in result.items():
        bound += bind_nested_receipts(
            item, request, op_id, error_type, derive, digest,
            f"{label}.{key}", read_challenge_digest,
        )
    if "capsule_receipt_version" in result:
        source = request["body"].get("capsule_source")
        expected_operation = source["source_operation_id"] if source else op_id
        channel = request["body"].get("secret_channel_binding", {})
        expected_channel = (
            source["issuance_secret_channel_binding_digest"]
            if source else channel.get("secret_channel_binding_digest")
        )
        if result["issuance_operation_id"] != expected_operation:
            raise error_type(f"{label}: capsule issuance operation does not match its source request")
        if result["issuance_secret_channel_binding_digest"] != expected_channel:
            raise error_type(f"{label}: capsule issuance channel does not match its source request")
        # Rehashing the caller's own request proves nothing about which
        # repository, operation, slot, or channel the data key was bound to.
        # The context is derived from the capsule's already-bound identity.
        request_core = result["key_attestation"]["generate_data_key_request"]
        derive(request_core, "encryption_context_digest", digest(
            "kms_encryption_context_digest", "GH700:kms-encryption-context:v1",
            {
                "authority_id": request["authority_id"],
                "repo_node_id": request["repo_node_id"],
                "capsule_id": result["capsule_id"],
                "issuance_operation_id": result["issuance_operation_id"],
                "issuance_secret_channel_binding_digest": result["issuance_secret_channel_binding_digest"],
            },
        ), label)
        bound += 1
    if "receipt_version" in result:
        for field in RECEIPT_REQUEST_BINDINGS:
            if result.get(field) != request[field]:
                raise error_type(
                    f"{label}: receipt {field} {result.get(field)!r} does not match the request"
                )
        # Frontier receipts are operation-independent snapshots and carry none.
        if "operation_id" in result and result["operation_id"] != op_id:
            raise error_type(f"{label}: receipt operation_id does not match this operation")
        if result["receipt_version"] == "GH700:capsule-read-receipt:v1":
            source = request["body"]["capsule_source"]
            channel = request["body"]["secret_channel_binding"]
            expected = (
                source["source_request_id"], read_challenge_digest,
                channel["secret_channel_binding_digest"],
            )
            actual = (
                result["source_request_id"], result["read_challenge_digest"],
                result["secret_channel_binding_digest"],
            )
            if actual != expected:
                raise error_type(f"{label}: capsule read confirmation does not match its request")
        bound += 1
    return bound

"""Typed-object semantic contracts selected by the GH700 binding matrix."""

import copy


def validate_kms_attestation(attestation, manifest, derive, digest, error_type, label):
    request = attestation["generate_data_key_request"]
    response = attestation["generate_data_key_response"]
    identity = (manifest["kms_key_arn"], manifest["kms_key_material_id"])
    observed = (
        (manifest["describe_key_response"]["key_id"], manifest["describe_key_response"]["key_material_id"]),
        (attestation["kms_key_arn"], attestation["kms_key_material_id"]),
        (request["key_id"], attestation["kms_key_material_id"]),
        (response["key_id"], response["key_material_id"]),
    )
    if any(item != identity for item in observed):
        raise error_type(f"{label}: KMS ARN/KeyMaterialId mismatch")
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
            for path in (("kms_key_arn",), ("kms_key_material_id",), ("key_attestation", "generate_data_key_request", "key_id"), ("key_attestation", "generate_data_key_response", "key_material_id"), ("key_attestation", "manifest_key_binding_digest")):
                mutated = copy.deepcopy(capsule)
                target = mutated
                for step in path[:-1]: target = target[step]
                if "material_id" in path[-1]:
                    replacement = "f" * 64
                elif path[-1].endswith("digest"):
                    replacement = "sha256:" + "e" * 64
                else:
                    replacement = "arn:aws:kms:us-east-1:111122223333:key/87654321-4321-4321-4321-cba987654321"
                target[path[-1]] = replacement
                try:
                    validate_nested_capsules(mutated, manifest, derive, digest, error_type, model_id)
                except error_type:
                    count += 1
                else:
                    raise error_type(f"{model_id}: nested KMS mutation accepted at {'.'.join(path)}")
    return count


def _walk(value):
    yield value
    children = value.values() if isinstance(value, dict) else value if isinstance(value, list) else ()
    for child in children:
        yield from _walk(child)

"""Exact machine-owned runtime domains for the GH700 digest formulas."""


CANONICAL_RUNTIME_DOMAIN_SETS = {
    "authorization_signing_preimage_digest": frozenset({
        "GH700:append-authorization:signing-preimage:v1",
        "GH700:delivery-authorization:signing-preimage:v1",
        "GH700:ledger-append-authorization:signing-preimage:v1",
        "GH700:publication-lease-authorization:signing-preimage:v1",
    }),
    "attempt_subject_key": frozenset({"GH700:attempt-subject:v1"}),
    "blocked_attempt_object_digest": frozenset({"GH700:blocked-attempt-record:v1"}),
    "liveness_policy_digest": frozenset({"GH700:liveness-policy:v1"}),
    "release_identity_attestation_digest": frozenset({"GH700:release-identity-attestation:v1"}),
    "kms_encryption_context_digest": frozenset({"GH700:kms-encryption-context:v1"}),
    "signature_digest": frozenset({None}),
    "client_request_nonce_digest": frozenset({"GH700:client-request-nonce:v1"}),
    "control_request_nonce_digest": frozenset({"GH700:control-request-nonce:v1"}),
    "time_bound_request_id": frozenset({"GH700:time-bound-request-id:v1"}),
    "execution_identity_digest": frozenset({"GH700:execution-identity:v1"}),
    "operation_id": frozenset({"GH700:operation-id:v1"}),
    "release_broker_delivery_id": frozenset({"GH700:release-broker-delivery-id:v1"}),
    "generated_pr_delivery_id": frozenset({"GH700:generated-pr-delivery-id:v1"}),
    "delivery_scope_digest": frozenset({"GH700:delivery-scope:v1"}),
    "recovery_query_digest": frozenset({"GH700:recovery-query:v1"}),
    "capsule_source_request_id": frozenset({"GH700:capsule-source-request-id:v1"}),
    "read_challenge_digest": frozenset({None}),
    "secret_channel_request_core_digest": frozenset({"GH700:secret-channel-request-core:v1"}),
    "tls_exporter_context_digest": frozenset({"GH700:tls-exporter-context:v1"}),
    "tls_exporter_keying_material_digest": frozenset({None}),
    "secret_channel_binding_digest": frozenset({"GH700:secret-channel-binding-digest:v1"}),
    "operation_request_digest": frozenset({
        "GH700:client-operation-request:v1", "GH700:control-operation-request:v1",
    }),
    "receipt_digest": frozenset({
        "GH700:capsule-read-receipt:v1", "GH700:control-receipt:v1",
        "GH700:enumeration-snapshot-receipt:v1", "GH700:frontier-receipt:v1",
        "GH700:ledger-receipt:v1", "GH700:transition-receipt:v1",
    }),
    "result_digest": frozenset({"GH700:client-result:v1", "GH700:control-result:v1"}),
    "response_nonce_digest": frozenset({
        "GH700:client-response-nonce:v1", "GH700:control-response-nonce:v1",
    }),
    "response_digest": frozenset({"GH700:client-response:v1", "GH700:control-response:v1"}),
    "prior_anchor_binding_digest": frozenset({
        "GH700:genesis-prior-anchor:v1", "GH700:prior-anchor:v1",
    }),
    "backup_aad_digest": frozenset({"GH700:backup-aad:v1"}),
    "describe_key_material_attestation_digest": frozenset({"GH700:describe-key-material-attestation:v1"}),
    "manifest_key_binding_digest": frozenset({"GH700:authority-kms-manifest-key-binding:v1"}),
    "generate_data_key_request_digest": frozenset({"GH700:generate-data-key-request:v1"}),
    "generate_data_key_material_attestation_digest": frozenset({"GH700:generate-data-key-material-attestation:v1"}),
    "key_attestation_digest": frozenset({"GH700:authority-capsule-key-attestation-digest:v1"}),
    "capsule_receipt_digest": frozenset({"GH700:authority-capsule-receipt:v1"}),
    "replay_row_digest": frozenset({"GH700:api-replay-row:v1"}),
}


def _walk(value):
    yield value
    children = value.values() if isinstance(value, dict) else value if isinstance(value, (list, tuple)) else ()
    for child in children:
        yield from _walk(child)


def _declared_domains(schema, node):
    declared = schema["x-gh700-digest-formulas"][node]["domain"]
    if declared == "exact branch domain in x-gh700-signing-preimages":
        return frozenset(item["domain"] for item in schema["x-gh700-signing-preimages"].values())
    if declared == "none; raw-byte digest":
        return frozenset({None})
    if declared in {"receipt.receipt_version", "capsule_receipt.capsule_receipt_version"}:
        field = declared.split(".")[-1]
        return frozenset(
            item[field]["const"] for item in _walk(schema)
            if isinstance(item, dict) and isinstance(item.get(field), dict) and "const" in item[field]
        )
    if "{client|control}" in declared:
        return frozenset(declared.replace("{client|control}", surface) for surface in ("client", "control"))
    return frozenset(declared.split(" or ")) if declared else frozenset()


def validate_domain_sets(schema, error_type=ValueError):
    formulas = schema.get("x-gh700-digest-formulas", {})
    if set(formulas) != set(CANONICAL_RUNTIME_DOMAIN_SETS):
        raise error_type("digest domain node set is not exact")
    for node, expected in CANONICAL_RUNTIME_DOMAIN_SETS.items():
        declared = _declared_domains(schema, node)
        if declared != expected:
            raise error_type(
                f"{node}: declared runtime domains are not exact; "
                f"expected={sorted(map(str, expected))} actual={sorted(map(str, declared))}"
            )


def allowed_domains(schema, node):
    validate_domain_sets(schema)
    return set(CANONICAL_RUNTIME_DOMAIN_SETS[node])


def require_domain(schema, node, domain, error_type=ValueError, context=None):
    try:
        validate_domain_sets(schema, error_type)
    except KeyError as exc:
        raise error_type(f"{node}: missing digest domain declaration") from exc
    if node not in CANONICAL_RUNTIME_DOMAIN_SETS or domain not in CANONICAL_RUNTIME_DOMAIN_SETS[node]:
        raise error_type(f"{node}: runtime domain is not schema-owned")
    contextual = {
        "operation_request_digest": f"GH700:{context}-operation-request:v1",
        "result_digest": f"GH700:{context}-result:v1",
        "response_nonce_digest": f"GH700:{context}-response-nonce:v1",
        "response_digest": f"GH700:{context}-response:v1",
    }
    if node in contextual:
        if context not in {"client", "control"} or domain != contextual[node]:
            raise error_type(f"{node}: contextual surface domain mismatch")
    if node == "authorization_signing_preimage_digest":
        expected = context.replace(":v1", ":signing-preimage:v1") if isinstance(context, str) else None
        if domain != expected:
            raise error_type(f"{node}: contextual authorization domain mismatch")
    if node == "receipt_digest" and domain != context:
        raise error_type(f"{node}: contextual receipt domain mismatch")
    return domain


def check_contextual_domain_rejections(schema, error_type=ValueError):
    count = 0
    suffixes = {
        "operation_request_digest": "operation-request",
        "result_digest": "result",
        "response_nonce_digest": "response-nonce",
        "response_digest": "response",
    }
    for node, suffix in suffixes.items():
        for surface, wrong_surface in (("client", "control"), ("control", "client")):
            try:
                require_domain(
                    schema, node, f"GH700:{wrong_surface}-{suffix}:v1", error_type, surface,
                )
            except error_type:
                count += 1
                continue
            raise error_type(f"{node}: cross-surface domain accepted for {surface}")
    return count

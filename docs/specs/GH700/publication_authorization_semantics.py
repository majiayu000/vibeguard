"""Request-bound semantic validation for GH700 authorization branches."""

import copy


AUTH_KEYS = (
    "publication_lease_authorization", "append_authorization",
    "delivery_authorization", "ledger_append_authorization",
)


def wrong_principal_mutations(request, response, model_id):
    for key in AUTH_KEYS:
        if key not in request["body"]:
            continue
        mutated_request, mutated_response = copy.deepcopy((request, response))
        principal = mutated_request["authenticated_principal_digest"]
        mutated_request["body"][key]["authenticated_principal_digest"] = (
            "sha256:" + ("e" if principal == "sha256:" + "f" * 64 else "f") * 64
        )
        mutated_request["body"][key]["signing_preimage_digest"] = {"$derive": "signing_preimage_digest"}
        mutated_request["operation_request_digest"] = {"$derive": "operation_request_digest"}
        mutated_response["response_digest"] = {"$derive": "response_digest"}
        yield f"{model_id}.{key}.wrong_principal_recomputed", key, mutated_request, mutated_response


def validate_authorization_bindings(request, body, op_id, derive, digest, error_type):
    method = request["method"]
    for key in AUTH_KEYS:
        auth = body.get(key)
        if not isinstance(auth, dict):
            continue
        if auth["authenticated_principal_digest"] != request["authenticated_principal_digest"]:
            raise error_type(f"{method}: authorization principal mismatch")
        if auth["authorized_method"] != method:
            raise error_type(f"{method}: authorization method mismatch")
        if key == "append_authorization":
            derive(auth, "authorized_operation_id", op_id, method)
            if auth["authorized_predecessor_frontier"] != request["expected_publication_frontier_or_null"]:
                raise error_type(f"{method}: append frontier mismatch")
        elif key == "ledger_append_authorization":
            derive(auth, "authorized_operation_id", op_id, method)
            if auth["authorized_predecessor_frontier"] != request["expected_blocked_attempt_frontier_or_null"]:
                raise error_type(f"{method}: ledger frontier mismatch")
        elif key == "delivery_authorization":
            delivery = body.get("broker_delivery_id", body.get("generated_pr_delivery_id"))
            derive(auth, "delivery_id", delivery, method)
            if auth["planned_operation_id"] != body["planned_operation_id"]:
                raise error_type(f"{method}: delivery binding mismatch")
            derive(auth, "delivery_scope_digest", digest(
                "delivery_scope_digest", "GH700:delivery-scope:v1",
                {"method": method, "planned_operation_id": body["planned_operation_id"], "delivery_id": delivery},
            ), method)

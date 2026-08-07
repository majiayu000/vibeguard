"""Closed binding-matrix evaluator for the GH700 authority API."""

import copy
import re


AUTH_KEYS = (
    "publication_lease_authorization", "append_authorization",
    "delivery_authorization", "ledger_append_authorization",
)

MATRIX_KEYS = {"matrix_version", "common_profiles", "profiles", "rows"}
ROW_KEYS = {
    "surface", "method", "request_ref", "success_ref", "frontier_profile",
    "authorization_ref", "operation_id_ref", "request_digest_domain",
    "result_digest_domain", "error_codes", "replay", "model_profiles", "finding_ids",
}
RELATION_KEYS = {
    "equal": {"relation_id", "operator", "left", "right", "mutation_kind"},
    "value": {"relation_id", "operator", "left", "value", "mutation_kind"},
    "greater_or_equal": {"relation_id", "operator", "left", "right", "mutation_kind"},
    "less_or_equal": {"relation_id", "operator", "left", "right", "mutation_kind"},
    "ordered_values": {"relation_id", "operator", "left", "values", "mutation_kind"},
}
PATH_RE = re.compile(r"^(request|response)(?:\.[a-z][a-z0-9_]*)+$")


def _fail(error_type, message):
    raise error_type(message)


def _path(root, path, error_type):
    if PATH_RE.fullmatch(path) is None:
        _fail(error_type, f"binding matrix path is not canonical: {path}")
    value = root
    for part in path.split("."):
        if not isinstance(value, dict) or part not in value:
            _fail(error_type, f"binding matrix path is absent: {path}")
        value = value[part]
    return value


def _relations(matrix, profile_names, error_type):
    profiles = matrix["profiles"]
    result = []
    seen = set()
    for name in (*matrix["common_profiles"], *profile_names):
        if name not in profiles:
            _fail(error_type, f"unknown binding profile: {name}")
        for relation in profiles[name]:
            relation_id = relation.get("relation_id")
            if relation_id in seen:
                _fail(error_type, f"duplicate active relation_id: {relation_id}")
            seen.add(relation_id)
            result.append(relation)
    return result


def validate_binding_matrix(schema, models, expected_rows, pointer, error_type=ValueError):
    matrix = schema.get("x-gh700-method-registry")
    if not isinstance(matrix, dict) or set(matrix) != MATRIX_KEYS:
        _fail(error_type, "method registry is not the sole closed binding matrix")
    if matrix["matrix_version"] != "GH700:operation-model-binding-matrix:v1":
        _fail(error_type, "unknown binding matrix version")
    profiles = matrix["profiles"]
    if not isinstance(profiles, dict) or not profiles:
        _fail(error_type, "binding profiles must be a non-empty object")
    if len(matrix["common_profiles"]) != len(set(matrix["common_profiles"])):
        _fail(error_type, "duplicate common binding profile")
    relation_ids = set()
    for name, relations in profiles.items():
        if not isinstance(name, str) or not isinstance(relations, list) or not relations:
            _fail(error_type, f"invalid binding profile: {name}")
        for relation in relations:
            operator = relation.get("operator") if isinstance(relation, dict) else None
            if operator not in RELATION_KEYS or set(relation) != RELATION_KEYS[operator]:
                _fail(error_type, f"closed relation shape mismatch in {name}")
            relation_id = relation["relation_id"]
            if relation_id in relation_ids:
                _fail(error_type, f"duplicate relation_id: {relation_id}")
            relation_ids.add(relation_id)
            for key in ("left", "right"):
                if key in relation and PATH_RE.fullmatch(relation[key]) is None:
                    _fail(error_type, f"non-canonical relation path: {relation[key]}")
    rows = matrix["rows"]
    keys = [(row.get("surface"), row.get("method")) for row in rows]
    if keys != list(expected_rows) or len(keys) != len(set(keys)):
        _fail(error_type, "binding matrix rows are not exact and unique")
    model_by_id = {model["model_id"]: model for model in models}
    if len(model_by_id) != len(models):
        _fail(error_type, "duplicate model_id")
    owned_models = []
    used_profiles = set(matrix["common_profiles"])
    for row in rows:
        if set(row) not in (ROW_KEYS, ROW_KEYS - {"finding_ids"}):
            _fail(error_type, f"closed matrix row shape mismatch: {row.get('method')}")
        pointer(schema, row["request_ref"])
        pointer(schema, row["success_ref"])
        if row["request_digest_domain"] != f"GH700:{row['surface']}-operation-request:v1":
            _fail(error_type, f"{row['method']}: contextual request domain mismatch")
        if row["result_digest_domain"] != f"GH700:{row['surface']}-result:v1":
            _fail(error_type, f"{row['method']}: contextual result domain mismatch")
        entries = row["model_profiles"]
        if not isinstance(entries, dict) or not entries:
            _fail(error_type, f"{row['method']}: empty model coverage")
        for model_id, names in entries.items():
            model = model_by_id.get(model_id)
            if model is None or (model["surface"], model["method"]) != (row["surface"], row["method"]):
                _fail(error_type, f"{row['method']}: unknown or cross-operation model {model_id}")
            if not isinstance(names, list) or len(names) != len(set(names)):
                _fail(error_type, f"{model_id}: duplicate/non-list profiles")
            used_profiles.update(names)
            _relations(matrix, names, error_type)
            owned_models.append(model_id)
    if len(owned_models) != len(set(owned_models)) or set(owned_models) != set(model_by_id):
        _fail(error_type, "every schema model must be owned exactly once")
    if used_profiles != set(profiles):
        _fail(error_type, "unknown or unused binding profile")
    return matrix


FRONTIER_PROFILES = {
    "NONE": (False, False, False),
    "P0_B0": (False, False, False),
    "P1_B0": (True, False, False),
    "P0_B1": (False, True, False),
    "P1_B1": (True, True, False),
    "BODY_P1_B1": (True, True, True),
}
REPLAY_MODES = {"durable_same_nonce_same_digest", "durable_same_nonce_same_digest_read_confirm"}


def _frontier_present(carrier, base):
    for key in (base, f"{base}_or_null"):
        if carrier.get(key) is not None:
            return True
    return False


def check_row_contract_fields(schema, rows, pairs, pointer, validate, error_type=ValueError):
    """Every binding-row field is a machine source, so validate all of them.

    Dereferencing only `request_ref`/`success_ref` lets `authorization_ref`,
    `operation_id_ref`, `frontier_profile`, `replay`, and `error_codes` hold
    wrong but well-formed values while the matrix still certifies.
    """
    checked = 0
    for row in rows:
        label = f"{row['surface']}.{row['method']}"
        for key in ("authorization_ref", "operation_id_ref"):
            ref = row[key]
            if ref is not None:
                pointer(schema, ref)
        if row["operation_id_ref"] not in (None, "#/$defs/operation_id"):
            _fail(error_type, f"{label}: operation_id_ref must be the shared operation_id or null")
        if row["replay"] not in REPLAY_MODES:
            _fail(error_type, f"{label}: unknown replay mode {row['replay']}")
        codes = row["error_codes"]
        if not codes or len(codes) != len(set(codes)):
            _fail(error_type, f"{label}: empty or duplicated error_codes")
        profile = row["frontier_profile"]
        if profile not in FRONTIER_PROFILES:
            _fail(error_type, f"{label}: unknown frontier profile {profile}")
        wants_publication, wants_blocked, in_body = FRONTIER_PROFILES[profile]

        for model_id in row["model_profiles"]:
            request = pairs[model_id][0]
            # Envelope frontiers are nullable (`*_or_null`); body frontiers are
            # required, so the same profile spells them under two names.
            carrier = request["body"] if in_body else request
            has_publication = _frontier_present(carrier, "expected_publication_frontier")
            has_blocked = _frontier_present(carrier, "expected_blocked_attempt_frontier")
            if (has_publication, has_blocked) != (wants_publication, wants_blocked):
                _fail(
                    error_type,
                    f"{model_id}: frontier profile {profile} disagrees with the wire "
                    f"(publication={has_publication} blocked={has_blocked})",
                )
            auth_ref = row["authorization_ref"]
            if auth_ref is not None:
                name = auth_ref.rsplit("/", 1)[-1]
                present = request["body"].get(name) if name in request["body"] else request.get("policy_binding")
                if present is None:
                    _fail(error_type, f"{model_id}: authorization_ref {auth_ref} names no wire member")
                # Presence is not agreement: a row can name a sibling
                # authorization whose fields the wire member does not satisfy.
                try:
                    validate(present, pointer(schema, auth_ref), schema)
                except Exception:
                    _fail(error_type, f"{model_id}: wire authorization does not satisfy authorization_ref {auth_ref}")
            checked += 1
    return checked


def row_for_model(matrix, model, error_type=ValueError):
    matches = [
        row for row in matrix["rows"]
        if model["model_id"] in row["model_profiles"]
    ]
    if len(matches) != 1:
        _fail(error_type, f"{model['model_id']}: model row cardinality mismatch")
    return matches[0]


def active_relations(matrix, row, model_id, error_type=ValueError):
    if model_id not in row["model_profiles"]:
        _fail(error_type, f"{model_id}: model is not owned by operation row")
    return _relations(matrix, row["model_profiles"][model_id], error_type)


_UINT64_DECIMAL = re.compile(r"0|[1-9][0-9]*")


def _as_uint64(value, label, error_type=ValueError):
    """Numeric view of a uint64 wire value; bools and non-canonical text fail."""
    if isinstance(value, bool):
        _fail(error_type, f"{label}: bool is not an ordered uint64 operand")
    if isinstance(value, int):
        return value
    if isinstance(value, str) and _UINT64_DECIMAL.fullmatch(value):
        return int(value)
    _fail(error_type, f"{label}: ordered relation operand is not a canonical uint64")


def validate_pair_bindings(request, response, matrix, row, model_id, error_type=ValueError):
    root = {"request": request, "response": response}
    for relation in active_relations(matrix, row, model_id, error_type):
        left = _path(root, relation["left"], error_type)
        operator = relation["operator"]
        if operator == "value":
            accepted = left == relation["value"]
        elif operator == "ordered_values":
            accepted = left == relation["values"]
        else:
            right = _path(root, relation["right"], error_type)
            if operator == "equal":
                accepted = left == right
            else:
                # uint64 values above 2^53-1 travel as canonical decimal
                # strings. Comparing them as raw JSON sorts them
                # lexicographically, which accepts numerically inverted
                # intervals, so ordering operands are coerced to integers.
                left_number = _as_uint64(left, relation["left"], error_type)
                right_number = _as_uint64(right, relation["right"], error_type)
                accepted = left_number >= right_number if operator == "greater_or_equal" else left_number <= right_number
        if not accepted:
            _fail(error_type, f"{model_id}: binding relation failed: {relation['relation_id']}")


def validate_common_bindings(request, response, matrix, error_type=ValueError):
    root = {"request": request, "response": response}
    for relation in _relations(matrix, (), error_type):
        if relation["operator"] != "equal" or _path(root, relation["left"], error_type) != _path(root, relation["right"], error_type):
            _fail(error_type, f"response binding relation failed: {relation['relation_id']}")


def derive_authorization_fields(body, op_id, method, derive, digest):
    """Materialize formula-owned authorization consumers; semantics live in the matrix."""
    if "append_authorization" in body:
        derive(body["append_authorization"], "authorized_operation_id", op_id, method)
    if "ledger_append_authorization" in body:
        derive(body["ledger_append_authorization"], "authorized_operation_id", op_id, method)
    if "delivery_authorization" in body:
        auth = body["delivery_authorization"]
        delivery_id = body.get("broker_delivery_id", body.get("generated_pr_delivery_id"))
        derive(auth, "delivery_id", delivery_id, method)
        derive(auth, "delivery_scope_digest", digest(
            "delivery_scope_digest", "GH700:delivery-scope:v1",
            {"method": method, "planned_operation_id": body["planned_operation_id"], "delivery_id": delivery_id},
        ), method)


def relation_mutations(request, response, matrix, row, model_id, mutate_value, error_type=ValueError):
    root = {"request": request, "response": response}
    for relation in active_relations(matrix, row, model_id, error_type):
        mutated_request, mutated_response = copy.deepcopy((request, response))
        mutated_root = {"request": mutated_request, "response": mutated_response}
        target = relation["left"]
        parts = target.split(".")
        container = mutated_root
        for part in parts[:-1]:
            container = container[part]
        if relation["operator"] == "greater_or_equal":
            replacement = _path(root, relation["right"], error_type) - 1
        elif relation["operator"] == "less_or_equal":
            replacement = _path(root, relation["right"], error_type) + 1
        else:
            replacement = mutate_value(_path(root, target, error_type), relation["mutation_kind"])
        container[parts[-1]] = replacement
        yield relation["relation_id"], mutated_request, mutated_response


def check_binding_matrix_mutations(schema, models, expected_rows, pointer, error_type=ValueError):
    cases = []
    def mutation(label, edit):
        candidate = copy.deepcopy(schema); edit(candidate["x-gh700-method-registry"]); cases.append((label, candidate))
    mutation("missing_row", lambda matrix: matrix["rows"].pop())
    mutation("duplicate_row", lambda matrix: matrix["rows"].append(copy.deepcopy(matrix["rows"][-1])))
    mutation("unknown_profile", lambda matrix: matrix["common_profiles"].append("unknown_profile"))
    mutation("missing_model", lambda matrix: matrix["rows"][0]["model_profiles"].pop(next(iter(matrix["rows"][0]["model_profiles"]))))
    mutation("duplicate_model", lambda matrix: matrix["rows"][1]["model_profiles"].update({next(iter(matrix["rows"][0]["model_profiles"])): []}))
    mutation("alias_path", lambda matrix: matrix["profiles"]["response_context"][0].update({"left": "response.policyBundleDigest"}))
    mutation("unknown_operator", lambda matrix: matrix["profiles"]["response_context"][0].update({"operator": "approximately_equal"}))
    mutation("unknown_row_field", lambda matrix: matrix["rows"][0].update({"compatibility_alias": True}))
    for label, candidate in cases:
        try:
            validate_binding_matrix(candidate, models, expected_rows, pointer, error_type)
        except error_type:
            continue
        raise error_type(f"binding matrix closure mutation accepted: {label}")
    return len(cases)

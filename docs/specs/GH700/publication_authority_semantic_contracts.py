#!/usr/bin/env python3
"""Cross-wire semantic contracts for the GH700 authority API verifier.

The entrypoint injects its canonicalizer, validator, and digest materializers so
this module can enforce pagination/bootstrap/schema relations without importing
the entrypoint or creating a circular dependency.
"""

import base64
import copy
import hashlib

from publication_digest_domains import require_domain, validate_domain_sets
from publication_schema_validator import compile_draft_2020_12_schema
from publication_signature_contract import sign_test_vector, verify, verify_or_materialize
from publication_wire_registries import SIGNING_BRANCHES


BOOTSTRAP_PROJECTION_FIELDS = (
    "publication_store_path", "volume_identity", "trusted_time_subject",
    "trusted_time_service", "quorum_policy_digest",
)
ENUMERATION_SIGNING_DOMAIN = "GH700:blocked-attempt-enumeration-snapshot:signing-preimage:v1"
ENUMERATION_CURSOR_DOMAIN = "GH700:blocked-attempt-enumeration-cursor:v1"
REQUIRED_DIGEST_NODES = {
    "attempt_subject_key", "blocked_attempt_object_digest", "kms_encryption_context_digest",
    "release_identity_attestation_digest", "liveness_policy_digest",
    "authorization_signing_preimage_digest", "signature_digest", "client_request_nonce_digest",
    "control_request_nonce_digest", "time_bound_request_id", "execution_identity_digest",
    "operation_id", "release_broker_delivery_id", "generated_pr_delivery_id",
    "delivery_scope_digest", "recovery_query_digest", "capsule_source_request_id",
    "read_challenge_digest", "secret_channel_request_core_digest", "tls_exporter_context_digest",
    "tls_exporter_keying_material_digest", "secret_channel_binding_digest",
    "operation_request_digest", "receipt_digest", "result_digest", "response_nonce_digest",
    "response_digest", "prior_anchor_binding_digest", "backup_aad_digest",
    "describe_key_material_attestation_digest", "manifest_key_binding_digest",
    "generate_data_key_request_digest", "generate_data_key_material_attestation_digest",
    "key_attestation_digest", "capsule_receipt_digest", "replay_row_digest",
}


class PublicationAuthoritySemanticContracts:
    """Dependency-injected semantic and mutation verifier for GH700."""

    def __init__(self, context):
        self.c = context

    @property
    def error(self):
        return self.c["error"]

    @property
    def signing_manifest(self):
        return self.c["get_signing_manifest"]()

    def bootstrap_projection(self, manifest):
        try:
            return {key: copy.deepcopy(manifest[key]) for key in BOOTSTRAP_PROJECTION_FIELDS}
        except KeyError as exc:
            raise self.error(f"deployment manifest missing bootstrap projection field: {exc.args[0]}") from exc

    def bootstrap_projection_digest(self, projection):
        return self.c["sha"](self.c["jcs"]({
            "v": "GH700:bootstrap-time-manifest-projection:v1", "projection": projection,
        }))

    def enumeration_query(self, request):
        return {
            "repo_node_id": request["repo_node_id"],
            **{key: request["body"][key] for key in (
                "source_identity_key", "candidate_identity_or_null", "run_id_or_null",
                "run_attempt_or_null", "attempt_record_kind_or_null", "attempt_subject_key_or_null",
            )},
        }

    def enumeration_record_key(self, record):
        fields = (
            "source_identity_key", "run_id", "run_attempt", "attempt_record_kind",
            "attempt_subject_key", "object_digest",
        )
        try:
            return tuple(self.c["jcs"](record[key]) for key in fields)
        except KeyError as exc:
            raise self.error(f"enumeration record missing canonical key field: {exc.args[0]}") from exc

    @staticmethod
    def enumeration_record_key_wire(record):
        return [record[key] for key in (
            "source_identity_key", "run_id", "run_attempt", "attempt_record_kind",
            "attempt_subject_key", "object_digest",
        )]

    @staticmethod
    def enumeration_record_matches_query(record, query):
        filters = (
            ("source_identity_key", "source_identity_key"),
            ("candidate_identity_or_null", "candidate_identity_or_null"),
            ("run_id_or_null", "run_id"), ("run_attempt_or_null", "run_attempt"),
            ("attempt_record_kind_or_null", "attempt_record_kind"),
            ("attempt_subject_key_or_null", "attempt_subject_key"),
        )
        return all(query_key != "source_identity_key" and query[query_key] is None
                   or record[record_key] == query[query_key]
                   for query_key, record_key in filters)

    def enumeration_cursor_payload(self, receipt, next_record):
        return {
            "v": ENUMERATION_CURSOR_DOMAIN,
            "snapshot_receipt_digest": self.c["sha"](self.c["jcs"](receipt)),
            "next_record_key": self.enumeration_record_key_wire(next_record),
            "expiry_policy_digest": self.signing_manifest["enumeration_cursor_expiry_policy_digest"],
        }

    def materialize_enumeration_cursor(self, receipt, next_record):
        payload = self.c["jcs"](self.enumeration_cursor_payload(receipt, next_record))
        message = bytes.fromhex(self.c["sha"](payload).removeprefix("sha256:"))
        return f"{self.c['b64u'](payload)}.{self.c['b64u'](sign_test_vector('authorization', message))}"

    def decode_b64u_variable(self, value, label):
        import re
        if not isinstance(value, str) or not value or "=" in value or re.fullmatch(r"[A-Za-z0-9_-]+", value) is None:
            raise self.error(f"{label}: canonical unpadded base64url required")
        try:
            raw = base64.b64decode(value + "=" * ((-len(value)) % 4), altchars=b"-_", validate=True)
        except ValueError as exc:
            raise self.error(f"{label}: invalid base64url") from exc
        if self.c["b64u"](raw) != value:
            raise self.error(f"{label}: byte-identical base64url re-encode mismatch")
        return raw

    def verify_enumeration_cursor(self, token, receipt, label):
        if not isinstance(token, str) or token.count(".") != 1:
            raise self.error(f"{label}: signed opaque cursor framing mismatch")
        payload_part, signature_part = token.split(".")
        payload_raw = self.decode_b64u_variable(payload_part, f"{label}.payload")
        try:
            payload = self.c["parse_json"](payload_raw.decode("utf-8"), f"{label}.payload")
        except UnicodeDecodeError as exc:
            raise self.error(f"{label}: cursor payload is not UTF-8 JSON") from exc
        expected_keys = {"v", "snapshot_receipt_digest", "next_record_key", "expiry_policy_digest"}
        if not isinstance(payload, dict) or set(payload) != expected_keys or self.c["jcs"](payload) != payload_raw:
            raise self.error(f"{label}: cursor payload is not exact canonical JSON")
        if payload["v"] != ENUMERATION_CURSOR_DOMAIN:
            raise self.error(f"{label}: cursor domain mismatch")
        if payload["snapshot_receipt_digest"] != self.c["sha"](self.c["jcs"](receipt)):
            raise self.error(f"{label}: cursor snapshot receipt binding mismatch")
        if payload["expiry_policy_digest"] != self.signing_manifest["enumeration_cursor_expiry_policy_digest"]:
            raise self.error(f"{label}: cursor expiry policy binding mismatch")
        key = payload["next_record_key"]
        if not isinstance(key, list) or len(key) != 6:
            raise self.error(f"{label}: cursor next record key mismatch")
        public_key = self.c["decode_b64u"](
            self.signing_manifest["enumeration_signing_public_key_b64u"], 32, f"{label}.public_key",
        )
        if hashlib.sha256(public_key).hexdigest() != self.signing_manifest["enumeration_signing_key_material_id"]:
            raise self.error(f"{label}: cursor verification key material mismatch")
        signature = self.c["decode_b64u"](signature_part, 64, f"{label}.signature")
        message = bytes.fromhex(self.c["sha"](payload_raw).removeprefix("sha256:"))
        if not verify(public_key, message, signature):
            raise self.error(f"{label}: cursor Ed25519 signature verification failed")
        return key

    def enumeration_receipt_digests(self, request, receipt, records, label):
        keys = [self.enumeration_record_key(record) for record in records]
        digests = [record["object_digest"] for record in records]
        if keys != sorted(keys) or len(keys) != len(set(keys)) or len(digests) != len(set(digests)):
            raise self.error(f"{label}: full record set is not in canonical record-key order or unique")
        derive, sha, jcs = self.c["derive"], self.c["sha"], self.c["jcs"]
        derive(receipt, "query_digest", sha(jcs({
            "v": "GH700:blocked-attempt-enumeration-query:v1",
            "enumeration_query": self.enumeration_query(request),
        })), label)
        derive(receipt, "snapshot_record_set_digest", sha(jcs(digests)), label)
        preimage_fields = (
            "repo_node_id", "query_digest", "snapshot_frontier", "snapshot_record_set_digest",
            "page_size", "issuer_key_id", "issuer_key_material_id",
        )
        signing_digest = sha(jcs({
            "v": ENUMERATION_SIGNING_DOMAIN, **{key: receipt[key] for key in preimage_fields},
        }))
        derive(receipt, "signing_preimage_digest", signing_digest, label)
        mapped_receipt = {
            "signing_key_id": receipt["issuer_key_id"],
            "signing_key_material_id": receipt["issuer_key_material_id"],
            "signature_b64u": receipt["signature_b64u"], "signature_digest": receipt["signature_digest"],
        }
        manifest = self.signing_manifest
        mapped_manifest = {
            "signature_algorithm": manifest["signature_algorithm"],
            "authorization_signing_key_id": manifest["enumeration_signing_key_id"],
            "authorization_signing_key_material_id": manifest["enumeration_signing_key_material_id"],
            "authorization_signing_public_key_b64u": manifest["enumeration_signing_public_key_b64u"],
        }
        require_domain(self.c["get_digest_schema"](), "signature_digest", None, self.error)
        verify_or_materialize(
            mapped_receipt, signing_digest, label, "authorization", mapped_manifest,
            self.c["decode_b64u"], self.c["b64u"], derive, sha, self.error,
        )
        receipt["signature_b64u"] = mapped_receipt["signature_b64u"]
        derive(receipt, "signature_digest", mapped_receipt["signature_digest"], label)

    @staticmethod
    def check_exact_typed_receipt(defs, error):
        expected = (
            "#/$defs/transition_receipt", "#/$defs/frontier_receipt", "#/$defs/control_receipt",
            "#/$defs/prebootstrap_time_ceremony_receipt", "#/$defs/enumeration_snapshot_receipt",
            "#/$defs/ledger_receipt", "#/$defs/capsule_read_receipt",
        )
        union = defs["typed_receipt"]
        if set(union) != {"oneOf"} or not isinstance(union["oneOf"], list):
            raise error("typed_receipt must contain exactly oneOf")
        if any(not isinstance(branch, dict) or set(branch) != {"$ref"} for branch in union["oneOf"]):
            raise error("typed_receipt branches must contain exactly one $ref")
        if tuple(branch["$ref"] for branch in union["oneOf"]) != expected:
            raise error("typed_receipt is not the exact canonical receipt union")

    def check_schema(self, schema, root):
        error, walk, pointer = self.error, self.c["walk"], self.c["pointer"]
        if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
            raise error("Draft 2020-12 declaration missing")
        compile_draft_2020_12_schema(schema, error)
        for label, keyword, value in (
            ("invalid type array", "type", ["string", 7]),
            ("invalid anchor plain-name", "$anchor", "bad/name"),
            ("invalid dynamicAnchor plain-name", "$dynamicAnchor", "1starts-with-digit"),
        ):
            malformed = copy.deepcopy(schema); malformed["$defs"]["id"][keyword] = value
            try: compile_draft_2020_12_schema(malformed, error)
            except error: pass
            else: raise error(f"Draft 2020-12 meta-schema mutation accepted: {label}")
        duplicate_anchor = copy.deepcopy(schema)
        duplicate_anchor["$defs"]["id"]["$anchor"] = "shared"
        duplicate_anchor["$defs"]["digest"]["$dynamicAnchor"] = "shared"
        try: compile_draft_2020_12_schema(duplicate_anchor, error)
        except error: pass
        else: raise error("same-resource $anchor/$dynamicAnchor duplicate accepted")
        distinct_resources = copy.deepcopy(schema)
        distinct_resources["$defs"]["id"].update({"$id": "urn:gh700:anchor-resource:id", "$anchor": "shared"})
        distinct_resources["$defs"]["digest"].update({"$id": "urn:gh700:anchor-resource:digest", "$dynamicAnchor": "shared"})
        compile_draft_2020_12_schema(distinct_resources, error)
        for constant in ("NaN", "Infinity", "-Infinity"):
            try: self.c["parse_json"](f'{{"value":{constant}}}', "non-finite mutation")
            except error: pass
            else: raise error(f"JSON loader accepted {constant}")
        refs = []
        for item in walk(schema):
            if isinstance(item, dict) and "$ref" in item:
                refs.append(item["$ref"]); pointer(schema, item["$ref"])
        self.c["check_scalars"](schema)
        defs = schema["$defs"]
        if any(item.get("x-gh700-semantic-validator") != "uint64" for item in walk(schema) if isinstance(item, dict) and "x-gh700-semantic-validator" in item):
            raise error("unknown semantic validator in schema")
        if defs["uint64"].get("x-gh700-semantic-validator") != "uint64":
            raise error("uint64 semantic validator binding missing")
        unevaluated_count = sum(item.get("unevaluatedProperties") is False for item in walk(schema) if isinstance(item, dict))
        if unevaluated_count == 0: raise error("closed allOf wire schemas missing unevaluatedProperties")
        methods = {"client": self.c["client_methods"], "control": self.c["control_methods"]}
        for name, surface in (("client_request_envelope", "client"), ("client_success_envelope", "client"), ("control_request_envelope", "control"), ("control_success_envelope", "control")):
            if tuple(defs[name]["properties"]["method"].get("enum", ())) != methods[surface]:
                raise error(f"{name}: open or reordered method enum")
        for name, surface in (("client_api_replay_row", "client"), ("control_api_replay_row", "control")):
            if tuple(defs[name]["properties"]["method"].get("enum", ())) != methods[surface]:
                raise error(f"{name}: missing closed method enum")
        for name in ("transition_receipt", "frontier_receipt", "control_receipt"):
            if not 8 <= len(defs[name]["required"]) <= 11: raise error(f"{name}: receipt must have 8-11 fields")
        enumeration_fields = {
            "repo_node_id", "query_digest", "snapshot_frontier", "snapshot_record_set_digest",
            "page_size", "issuer_key_id", "issuer_key_material_id", "signing_preimage_digest",
            "signature_b64u", "signature_digest",
        }
        if set(defs["enumeration_snapshot_receipt"]["required"]) != enumeration_fields:
            raise error("enumeration_snapshot_receipt: exact signed ten-field wire required")
        if "receipt" in defs and len(defs["receipt"].get("required", ())) == 2:
            raise error("generic two-field receipt remains")
        signing = {"signing_key_id", "signing_key_material_id", "signing_preimage_digest", "signature_b64u", "signature_digest"}
        signing_meta = schema.get("x-gh700-signing-preimages", {})
        if set(signing_meta) != set(SIGNING_BRANCHES):
            raise error(f"signing preimage registry is not exactly {sorted(SIGNING_BRANCHES)}")
        for name in SIGNING_BRANCHES:
            if not signing <= set(defs[name]["required"]): raise error(f"{name}: incomplete signing contract")
            meta = signing_meta.get(name, {})
            expected_fields = [field for field in defs[name]["required"] if field not in {"signing_preimage_digest", "signature_b64u", "signature_digest"}]
            if meta.get("domain") != defs[name]["properties"]["schema_version"]["const"].replace(":v1", ":signing-preimage:v1") or meta.get("preimage_fields") != expected_fields or "manifest-pinned" not in meta.get("key_binding", ""):
                raise error(f"{name}: signing preimage/key metadata mismatch")
        enumeration_meta = schema.get("x-gh700-enumeration-signing-preimage", {})
        expected_preimage = [field for field in defs["enumeration_snapshot_receipt"]["required"] if field not in {"signing_preimage_digest", "signature_b64u", "signature_digest"}]
        if enumeration_meta.get("domain") != ENUMERATION_SIGNING_DOMAIN or enumeration_meta.get("preimage_fields") != expected_preimage or enumeration_meta.get("signature_digest") != "SHA256(decoded canonical 64-byte signature_b64u)" or "manifest-pinned enumeration verification key" not in enumeration_meta.get("key_binding", ""):
            raise error("enumeration signing preimage/key metadata mismatch")
        manifest_fields = set(defs["authority_signing_manifest"]["required"])
        if not {"enumeration_signing_key_id", "enumeration_signing_key_material_id", "enumeration_signing_public_key_b64u", "enumeration_cursor_expiry_policy_digest"} <= manifest_fields:
            raise error("authority signing manifest does not pin the enumeration verification key")
        self.check_exact_typed_receipt(defs, error)
        for label, mutate in (
            ("top-level extra keyword", lambda union: union.update({"not": {}})),
            ("branch extra keyword", lambda union: union["oneOf"][0].update({"not": {}})),
        ):
            mutated = copy.deepcopy(defs); mutate(mutated["typed_receipt"])
            try: self.check_exact_typed_receipt(mutated, error)
            except error: pass
            else: raise error(f"typed_receipt exact-union mutation accepted: {label}")
        control_receipt = defs["control_receipt"]
        if "prebootstrap_time_prepared" in control_receipt["properties"]["receipt_kind"]["enum"] or "prepare_bootstrap_trusted_time" in control_receipt["properties"]["method"]["enum"] or any(item.get("if", {}).get("properties", {}).get("method", {}).get("const") == "prepare_bootstrap_trusted_time" for item in control_receipt.get("allOf", ())):
            raise error("generic control_receipt still accepts the prebootstrap ceremony")
        material_schema = defs["authority_capsule_key_attestation"]["properties"]["kms_key_material_id"]
        if material_schema.get("$ref"): material_schema = pointer(schema, material_schema["$ref"])
        if material_schema.get("pattern") != "^[0-9a-f]{64}$": raise error("KeyMaterialId is not exact 64hex")
        if "selector" not in defs["control_body_recover"]["required"]: raise error("control recovery selector missing")
        deployment, projection = defs["deployment_manifest"], defs["bootstrap_time_manifest_projection"]
        if deployment["properties"].get("deployment_policy") != {"$ref": "#/$defs/deployment_policy_binding"} or any(item.get("$ref") == "#/$defs/prebootstrap_policy_binding" for item in walk(deployment) if isinstance(item, dict)):
            raise error("history deployment manifest policy branch is not deployment-only")
        if set(projection.get("required", ())) != set(BOOTSTRAP_PROJECTION_FIELDS):
            raise error("bootstrap time manifest projection is not the exact deterministic field set")
        if not set(BOOTSTRAP_PROJECTION_FIELDS) <= set(deployment.get("required", ())):
            raise error("deployment manifest cannot reconstruct the prepared bootstrap projection")
        if any(deployment["properties"].get(key) != projection["properties"].get(key) for key in BOOTSTRAP_PROJECTION_FIELDS):
            raise error("deployment manifest projection field schemas drifted from the prepared projection")
        for field, (ref, object_kind) in {
            "trusted_time_subject": ("#/$defs/bootstrap_trusted_time_subject_ref", "bootstrap_initial_time"),
            "trusted_time_service": ("#/$defs/trusted_time_service_ref", "trusted_time_service"),
        }.items():
            definition = pointer(schema, ref)
            if projection["properties"].get(field) != {"$ref": ref} or definition["properties"]["object_kind"] != {"const": object_kind}:
                raise error(f"{field}: dedicated exact reference contract missing")
        owners = {"authorization": "#/$defs/authorization", "receipt": "#/$defs/typed_receipt", "digest": "#/x-gh700-digest-formulas", "replay": "#/$defs/replay_row", "kms": "#/$defs/authority_kms_manifest"}
        if schema.get("x-gh700-wire-owners") != owners or len(set(owners.values())) != 5:
            raise error("wire owner map mismatch")
        for ref in owners.values(): pointer(schema, ref)
        forbidden = set(schema["x-gh700-forbidden-aliases"])
        for name, definition in defs.items():
            if name in forbidden: raise error(f"forbidden alias definition: {name}")
            for item in walk(definition):
                if isinstance(item, dict) and (forbidden & (set(item.get("required", ())) | set(item.get("properties", {})))):
                    raise error(f"forbidden alias field in {name}")
        compact = "".join((root / name).read_text(encoding="utf-8").replace(" ", "") for name in ("publication_history_contract.md", "publication_ledger_contract.md", "publication_authority_protocol_contract.md"))
        for marker in ('"schema_version":"GH700:append-authorization:v1"', '"schema_version":"GH700:delivery-authorization:v1"', '"schema_version":"GH700:ledger-append-authorization:v1"', '"receipt_version":"GH700:'):
            if marker in compact: raise error(f"duplicate prose wire owner: {marker}")
        return len(refs), unevaluated_count

    def check_dag(self, schema):
        error = self.error
        dag, formulas = schema["x-gh700-digest-dag"], schema["x-gh700-digest-formulas"]
        nodes = dag["nodes"]
        if schema.get("x-gh700-digest-framing") != "digest = lowercase sha256:<64hex> of SHA256(JCS({v:domain,...preimage_fields})); callers may not supply v":
            raise error("digest framing mismatch")
        if len(nodes) != len(set(nodes)) or set(nodes) != set(formulas) or set(nodes) != REQUIRED_DIGEST_NODES:
            raise error("digest formula/DAG node mismatch")
        validate_domain_sets(schema, error)
        for name, formula in formulas.items():
            if set(formula) != {"domain", "preimage", "wire_consumers"} or not all(formula.values()):
                raise error(f"incomplete digest formula: {name}")
        outgoing, indegree = {node: [] for node in nodes}, {node: 0 for node in nodes}
        for source, target in dag["edges"]:
            if source not in outgoing or target not in outgoing or source == target: raise error("invalid digest DAG edge")
            outgoing[source].append(target); indegree[target] += 1
        queue, seen = [node for node in nodes if indegree[node] == 0], 0
        while queue:
            node = queue.pop(0); seen += 1
            for target in outgoing[node]:
                indegree[target] -= 1
                if indegree[target] == 0: queue.append(target)
        if seen != len(nodes): raise error("digest DAG cycle")
        return len(nodes), len(dag["edges"])

    def check_digest_node_mutations(self, schema):
        count, error = 0, self.error
        validate_domain_sets(schema, error)
        for node in schema["x-gh700-digest-dag"]["nodes"]:
            original = schema["x-gh700-digest-formulas"][node]["domain"]
            for kind, replacement in (("added", original + f" or GH700:mutation-added:{node}:v1"), ("removed", ""), ("replaced", f"GH700:mutation-replaced:{node}:v1")):
                mutated = copy.deepcopy(schema); mutated["x-gh700-digest-formulas"][node]["domain"] = replacement
                try: validate_domain_sets(mutated, error)
                except error: count += 1; continue
                raise error(f"digest node {kind} mutation accepted: {node}")
        if count != 3 * len(REQUIRED_DIGEST_NODES): raise error("digest mutation matrix is incomplete")
        return count

    def prebootstrap_time_ceremony_id(self, request):
        body, policy, sha, jcs = request["body"], request["policy_binding"], self.c["sha"], self.c["jcs"]
        projection_digest = self.bootstrap_projection_digest(body["bootstrap_time_manifest_projection"])
        approval_digest = body["prebootstrap_time_approval"]["object_digest"]
        if projection_digest != policy["projection_digest"]: raise self.error("prepare_bootstrap_trusted_time: projection digest mismatch")
        if approval_digest != policy["prebootstrap_time_approval_digest"]: raise self.error("prepare_bootstrap_trusted_time: approval digest mismatch")
        return sha(jcs({
            "v": "GH700:prebootstrap-time-ceremony:v1", "authority_id": request["authority_id"],
            "repo_node_id": request["repo_node_id"], "projection_digest": projection_digest,
            "prebootstrap_time_approval_digest": approval_digest,
            "release_identity_attestation_digest": body["release_identity_attestation"]["attestation_digest"],
        }))

    def check_enumeration_pages(self, pages):
        if not pages: raise self.error("list_blocked_attempts: at least one page required")
        initial_request, expected_cursor, expected_key = pages[0][0], None, None
        initial_query = self.enumeration_query(initial_request)
        common_receipt, all_records, seen_cursors = None, [], set()
        for index, (request, response) in enumerate(pages):
            body, result = request["body"], response["result"]
            if self.enumeration_query(request) != self.enumeration_query(initial_request): raise self.error("list_blocked_attempts: query changed across pages")
            if body["page_cursor_or_null"] != expected_cursor: raise self.error("list_blocked_attempts: cursor chain mismatch")
            records = result["attempt_records"]
            if expected_key is not None and (not records or self.enumeration_record_key_wire(records[0]) != expected_key):
                raise self.error("list_blocked_attempts: cursor next record key mismatch")
            receipt = result["enumeration_snapshot_receipt"]
            if receipt["repo_node_id"] != request["repo_node_id"]: raise self.error("list_blocked_attempts: snapshot receipt repo mismatch")
            if receipt["snapshot_frontier"] != request["expected_blocked_attempt_frontier_or_null"]: raise self.error("list_blocked_attempts: snapshot frontier mismatch")
            if receipt["page_size"] != body["page_size"]: raise self.error("list_blocked_attempts: snapshot page size mismatch")
            if len(records) > receipt["page_size"]: raise self.error("list_blocked_attempts: page exceeds the signed page size")
            if any(not self.enumeration_record_matches_query(record, initial_query) for record in records):
                raise self.error("list_blocked_attempts: visible record does not satisfy the signed query filters")
            if common_receipt is None: common_receipt = receipt
            elif self.c["jcs"](receipt) != self.c["jcs"](common_receipt): raise self.error("list_blocked_attempts: receipt changed across pages")
            all_records.extend(records)
            next_cursor, is_final = result["next_page_cursor_or_null"], index == len(pages) - 1
            if is_final != (next_cursor is None): raise self.error("list_blocked_attempts: only the final page may terminate the cursor chain")
            if next_cursor is not None:
                if next_cursor in seen_cursors: raise self.error("list_blocked_attempts: repeated cursor")
                seen_cursors.add(next_cursor)
                expected_key = self.verify_enumeration_cursor(next_cursor, receipt, f"list_blocked_attempts.page[{index}].cursor")
            else: expected_key = None
            expected_cursor = next_cursor
        self.enumeration_receipt_digests(initial_request, common_receipt, all_records, "list_blocked_attempts")

    def check_prebootstrap_ceremony(self, pairs):
        prepare_request, prepare_response = pairs["control.prepare_bootstrap_trusted_time"]
        bootstrap_request = pairs["control.bootstrap"][0]
        receipt = prepare_response["result"]["prebootstrap_time_ceremony_receipt"]
        ceremony_id = self.prebootstrap_time_ceremony_id(prepare_request)
        projected = self.bootstrap_projection(bootstrap_request["body"]["deployment_manifest"])
        prepared = prepare_request["body"]["bootstrap_time_manifest_projection"]
        if self.c["jcs"](projected) != self.c["jcs"](prepared): raise self.error("bootstrap: deployment manifest projection does not byte-equal the prepared projection")
        expected = {
            "prebootstrap_time_ceremony_id": ceremony_id,
            "projection_digest": self.bootstrap_projection_digest(projected),
            "prebootstrap_time_approval_digest": prepare_request["policy_binding"]["prebootstrap_time_approval_digest"],
            "release_identity_attestation_digest": prepare_request["body"]["release_identity_attestation"]["attestation_digest"],
            "initial_time_proof_bundle_digest": self.c["sha"](self.c["jcs"](prepare_response["result"]["initial_time_proof_bundle"])),
        }
        for key, value in expected.items():
            if receipt[key] != value: raise self.error(f"prepare_bootstrap_trusted_time: {key} mismatch")
        if bootstrap_request["body"]["prebootstrap_time_ceremony_id"] != ceremony_id: raise self.error("bootstrap: cross-ceremony ID mismatch")
        if bootstrap_request["body"]["prebootstrap_time_ceremony_receipt_digest"] != receipt["receipt_digest"]: raise self.error("bootstrap: cross-ceremony receipt mismatch")
        if bootstrap_request["body"]["release_identity_attestation"]["attestation_digest"] != expected["release_identity_attestation_digest"]: raise self.error("bootstrap: ceremony release identity mismatch")

    def check_cross_contract_mutations(self, pairs, schema):
        rejected, error = 0, self.error
        validate, pointer = self.c["validate"], self.c["pointer"]
        list_request, list_response = pairs["client.list_blocked_attempts"]
        for key, value in (
            ("query_digest", "sha256:" + "e" * 64),
            ("snapshot_frontier", {**list_request["expected_blocked_attempt_frontier_or_null"], "full_prefix_digest": "sha256:" + "e" * 64}),
            ("snapshot_record_set_digest", "sha256:" + "e" * 64), ("page_size", list_request["body"]["page_size"] + 1),
            ("issuer_key_id", "untrusted-enumeration-key"), ("issuer_key_material_id", "e" * 64),
            ("signing_preimage_digest", "sha256:" + "e" * 64),
        ):
            mutated = copy.deepcopy(list_response); mutated["result"]["enumeration_snapshot_receipt"][key] = value
            try: self.check_enumeration_pages(((list_request, mutated),))
            except error: rejected += 1
            else: raise error(f"list_blocked_attempts: {key} substitution accepted")
        first_request, second_request = copy.deepcopy(list_request), copy.deepcopy(list_request)
        first_response, second_response = copy.deepcopy(list_response), copy.deepcopy(list_response)
        source_identity_key = list_request["body"]["source_identity_key"]
        records = [{
            "schema_version": "GH700:ledger-object-ref:v1", "object_kind": "blocked_attempt_record",
            "object_digest": "sha256:" + "2" * 64, "source_identity_key": source_identity_key,
            "candidate_identity_or_null": "sha256:" + "6" * 64,
            "run_id": 1, "run_attempt": 1, "attempt_record_kind": "candidate_failure",
            "attempt_subject_key": "sha256:" + "3" * 64,
        }, {
            "schema_version": "GH700:ledger-object-ref:v1", "object_kind": "blocked_attempt_record",
            "object_digest": "sha256:" + "1" * 64, "source_identity_key": source_identity_key,
            "candidate_identity_or_null": "sha256:" + "7" * 64,
            "run_id": 2, "run_attempt": 1, "attempt_record_kind": "candidate_failure",
            "attempt_subject_key": "sha256:" + "5" * 64,
        }]
        first_response["result"]["attempt_records"] = [copy.deepcopy(records[0])]
        second_response["result"]["attempt_records"] = [copy.deepcopy(records[1])]
        second_response["result"]["next_page_cursor_or_null"] = None
        receipt = copy.deepcopy(first_response["result"]["enumeration_snapshot_receipt"])
        for key in ("snapshot_record_set_digest", "signing_preimage_digest", "signature_b64u", "signature_digest"): receipt[key] = {"$derive": key}
        self.enumeration_receipt_digests(first_request, receipt, records, "two-page enumeration fixture")
        first_response["result"]["enumeration_snapshot_receipt"] = copy.deepcopy(receipt)
        second_response["result"]["enumeration_snapshot_receipt"] = copy.deepcopy(receipt)
        cursor = self.materialize_enumeration_cursor(receipt, records[1])
        first_response["result"]["next_page_cursor_or_null"] = cursor
        second_request["body"]["page_cursor_or_null"] = cursor
        second_request["request_nonce"] = self.c["b64u"](b"\x02" * 32)
        second_request["operation_request_digest"] = {"$derive": "operation_request_digest"}
        first_op, first_nonce = self.c["request_digests"](first_request, "client")
        second_op, second_nonce = self.c["request_digests"](second_request, "client")
        for request, response, op_id, nonce_digest in ((first_request, first_response, first_op, first_nonce), (second_request, second_response, second_op, second_nonce)):
            response["operation_request_digest"] = request["operation_request_digest"]
            response["client_request_nonce_digest"] = {"$derive": "client_request_nonce_digest"}
            response["result_digest"] = {"$derive": "result_digest"}; response["response_digest"] = {"$derive": "response_digest"}
            self.c["response_digests"](response, request, "client", op_id, nonce_digest, enumeration_records=records)
        pages = ((first_request, first_response), (second_request, second_response))
        for request, response in pages:
            validate(request, pointer(schema, "#/$defs/client_request_list_blocked_attempts"), schema)
            validate(response, pointer(schema, "#/$defs/client_success_list_blocked_attempts"), schema)
        self.check_enumeration_pages(pages)

        def signed_single_page(query_patch, visible_records, page_size, label, receipt_patch=None):
            request, response = copy.deepcopy((list_request, list_response))
            request["body"].update(query_patch); request["body"]["page_size"] = page_size
            request["operation_request_digest"] = {"$derive": "operation_request_digest"}
            response["result"]["attempt_records"] = copy.deepcopy(visible_records)
            response["result"]["next_page_cursor_or_null"] = None
            target = response["result"]["enumeration_snapshot_receipt"]
            target.update(receipt_patch or {})
            target["page_size"] = page_size
            for key in ("query_digest", "snapshot_record_set_digest", "signing_preimage_digest", "signature_b64u", "signature_digest"):
                target[key] = {"$derive": key}
            op_id, nonce_digest = self.c["request_digests"](request, "client")
            response["operation_request_digest"] = request["operation_request_digest"]
            response["client_request_nonce_digest"] = {"$derive": "client_request_nonce_digest"}
            response["result_digest"] = {"$derive": "result_digest"}; response["response_digest"] = {"$derive": "response_digest"}
            self.c["response_digests"](response, request, "client", op_id, nonce_digest, enumeration_records=visible_records)
            validate(request, pointer(schema, "#/$defs/client_request_list_blocked_attempts"), schema)
            validate(response, pointer(schema, "#/$defs/client_success_list_blocked_attempts"), schema)
            return ((request, response),)

        overflow = signed_single_page({}, records, 1, "page-size overflow")
        try: self.check_enumeration_pages(overflow)
        except error: rejected += 1
        else: raise error("list_blocked_attempts: signed schema-valid page-size overflow accepted")
        for query_key, mismatch in (
            ("source_identity_key", "sha256:" + "8" * 64),
            ("candidate_identity_or_null", "sha256:" + "8" * 64),
            ("run_id_or_null", 8), ("run_attempt_or_null", 8),
            ("attempt_record_kind_or_null", "pipeline_interrupted"),
            ("attempt_subject_key_or_null", "sha256:" + "8" * 64),
        ):
            out_of_filter = signed_single_page({query_key: mismatch}, [records[0]], 1, query_key)
            try: self.check_enumeration_pages(out_of_filter)
            except error: rejected += 1
            else: raise error(f"list_blocked_attempts: signed schema-valid out-of-filter {query_key} record accepted")
        wrong_repo = signed_single_page(
            {}, [records[0]], 1, "receipt repo mismatch", {"repo_node_id": "R_GH700_OTHER"},
        )
        try: self.check_enumeration_pages(wrong_repo)
        except error: rejected += 1
        else: raise error("list_blocked_attempts: authority-resigned receipt repo mismatch accepted")
        try: self.c["response_digests"](copy.deepcopy(second_response), second_request, "client", second_op, second_nonce)
        except error: rejected += 1
        else: raise error("list_blocked_attempts: final page verified without the accumulated full record set")
        digest_paths = []
        def collect(value, path=()):
            if isinstance(value, dict):
                for child_key, child in value.items(): collect(child, path + (child_key,))
            elif isinstance(value, str) and value.startswith("sha256:"): digest_paths.append(path)
        collect(receipt)
        for path in digest_paths:
            mutated = copy.deepcopy(pages); target = mutated[0][1]["result"]["enumeration_snapshot_receipt"]
            for part in path[:-1]: target = target[part]
            target[path[-1]] = "sha256:" + "e" * 64
            try: self.check_enumeration_pages(mutated)
            except error: rejected += 1
            else: raise error(f"list_blocked_attempts: non-final receipt digest substitution accepted at {path}")
        tampered = copy.deepcopy(pages)
        raw_signature = bytearray(self.c["decode_b64u"](receipt["signature_b64u"], 64, "enumeration mutation")); raw_signature[0] ^= 1
        for _, response in tampered:
            target = response["result"]["enumeration_snapshot_receipt"]
            target["signature_b64u"] = self.c["b64u"](bytes(raw_signature)); target["signature_digest"] = self.c["sha"](bytes(raw_signature))
        try: self.check_enumeration_pages(tampered)
        except error: rejected += 1
        else: raise error("list_blocked_attempts: forged Ed25519 signature accepted")
        tampered = copy.deepcopy(pages); payload_part, signature_part = cursor.split(".")
        raw_cursor = bytearray(self.c["decode_b64u"](signature_part, 64, "cursor mutation")); raw_cursor[0] ^= 1
        bad_cursor = f"{payload_part}.{self.c['b64u'](bytes(raw_cursor))}"
        tampered[0][1]["result"]["next_page_cursor_or_null"] = bad_cursor; tampered[1][0]["body"]["page_cursor_or_null"] = bad_cursor
        try: self.check_enumeration_pages(tampered)
        except error: rejected += 1
        else: raise error("list_blocked_attempts: forged store-signed cursor accepted")
        wrong = copy.deepcopy(pages); bad_cursor = self.materialize_enumeration_cursor(receipt, records[0])
        wrong[0][1]["result"]["next_page_cursor_or_null"] = bad_cursor; wrong[1][0]["body"]["page_cursor_or_null"] = bad_cursor
        try: self.check_enumeration_pages(wrong)
        except error: rejected += 1
        else: raise error("list_blocked_attempts: cursor bound to wrong next record key accepted")
        omitted = copy.deepcopy(pages); omitted[1][1]["result"]["attempt_records"] = []
        try: self.check_enumeration_pages(omitted)
        except error: rejected += 1
        else: raise error("list_blocked_attempts: incomplete cross-page record set accepted")
        watermark = pairs["client.commit_reconciliation_watermark"][0]
        for key in ("reconciliation_watermark", "terminal_listing_proof"):
            mutated = copy.deepcopy(watermark["body"]); mutated[key]["object_kind"] = "blocked_attempt_record"
            try: validate(mutated, pointer(schema, "#/$defs/body_watermark_exact"), schema)
            except error: rejected += 1
            else: raise error(f"commit_reconciliation_watermark: {key} kind substitution accepted")
        for key in ("prebootstrap_time_ceremony_id", "prebootstrap_time_ceremony_receipt_digest"):
            mutated = copy.deepcopy(pairs); request = mutated["control.bootstrap"][0]
            request["body"][key] = "sha256:" + "e" * 64; request["body"]["control_operation_id"] = {"$derive": "control_operation_id"}; request["operation_request_digest"] = {"$derive": "operation_request_digest"}
            self.c["request_digests"](request, "control")
            try: self.check_prebootstrap_ceremony(mutated)
            except error: rejected += 1
            else: raise error(f"bootstrap: {key} substitution accepted")
        mutated = copy.deepcopy(pairs); request = mutated["control.bootstrap"][0]
        request["body"]["deployment_manifest"]["volume_identity"] = "volume-mutated-only-at-bootstrap"
        request["body"]["control_operation_id"] = {"$derive": "control_operation_id"}; request["operation_request_digest"] = {"$derive": "operation_request_digest"}
        self.c["request_digests"](request, "control")
        try: self.check_prebootstrap_ceremony(mutated)
        except error: rejected += 1
        else: raise error("bootstrap: manifest-only projection mutation accepted")
        projection = pairs["control.prepare_bootstrap_trusted_time"][0]["body"]["bootstrap_time_manifest_projection"]
        for field, object_kind in (("trusted_time_subject", "trusted_time_service"), ("trusted_time_subject", "wrong_trusted_time_subject"), ("trusted_time_service", "bootstrap_initial_time"), ("trusted_time_service", "wrong_trusted_time_service")):
            mutated = copy.deepcopy(projection); mutated[field]["object_kind"] = object_kind
            try: validate(mutated, pointer(schema, "#/$defs/bootstrap_time_manifest_projection"), schema)
            except error: rejected += 1
            else: raise error(f"bootstrap: {field} wrong/cross object kind accepted: {object_kind}")
        return rejected

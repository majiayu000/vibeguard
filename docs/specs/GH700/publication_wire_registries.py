#!/usr/bin/env python3
"""Exact-set closures over the schema-owned wire registries.

Presence-and-truthiness checks let a registry stay green while its contents
drift: an extra signing branch reusing a live domain, a digest formula whose
preimage was rewritten, a digest DAG that dropped a required dependency, or a
method whose error enum no longer matches its registry row. Each check here
compares against an exact expectation and is paired with a mutation that must
be rejected, so drift fails the gate instead of being certified.
"""

import hashlib

SIGNING_BRANCHES = (
    "publication_lease_authorization",
    "append_authorization",
    "delivery_authorization",
    "ledger_append_authorization",
)

# Canonical digests over the schema-owned digest registries. They pin the exact
# contents of `x-gh700-digest-formulas` and `x-gh700-digest-dag`, so any added,
# removed, or rewritten formula/edge fails the gate and has to be re-approved
# here deliberately rather than sliding through an endpoint-validity check.
TRUSTED_REGISTRY_ANCHORS = {
    "x-gh700-digest-formulas": (
        "x-gh700-digest-formulas-anchor",
        "sha256:fe1de974a85b57aaa86c42d895118aa3c976344882aa3d7e6e3ad9acd71ee986",
    ),
    "x-gh700-digest-dag": (
        "x-gh700-digest-dag-anchor",
        "sha256:2c106d428d4d95817e90be4575e8a8808b3a43ac9f5babc580120ef2a4fe84cb",
    ),
}


def anchor_digest(value, jcs):
    """Anchor over the caller's canonical JCS bytes — one canonicalizer only."""
    return "sha256:" + hashlib.sha256(jcs(value)).hexdigest()


def check_registry_anchors(schema, jcs, error):
    """Pin the digest formula and DAG registries to their approved contents."""
    checked = 0
    for key, (anchor_key, trusted) in TRUSTED_REGISTRY_ANCHORS.items():
        registry = schema.get(key)
        if not isinstance(registry, dict):
            raise error(f"{key}: missing registry")
        declared = schema.get(anchor_key)
        actual = anchor_digest(registry, jcs)
        if declared != trusted or actual != trusted:
            raise error(
                f"{key}: registry anchor mismatch "
                f"(trusted={trusted} declared={declared} actual={actual})"
            )
        checked += 1
    return checked


def check_registry_anchor_mutations(schema, jcs, error):
    """An added, removed, or rewritten registry entry must break the anchor."""
    mutations = 0
    formulas = schema["x-gh700-digest-formulas"]
    dag = schema["x-gh700-digest-dag"]
    name = sorted(formulas)[0]

    variants = [
        ("formula preimage rewritten", {**formulas, name: {**formulas[name], "preimage": "nonsense"}}, "x-gh700-digest-formulas"),
        ("formula wire_consumers rewritten", {**formulas, name: {**formulas[name], "wire_consumers": ["nonsense"]}}, "x-gh700-digest-formulas"),
        ("formula removed", {key: item for key, item in formulas.items() if key != name}, "x-gh700-digest-formulas"),
        ("dag edges cleared", {**dag, "edges": []}, "x-gh700-digest-dag"),
        ("dag edge removed", {**dag, "edges": dag["edges"][1:]}, "x-gh700-digest-dag"),
        ("dag edge added", {**dag, "edges": dag["edges"] + [[dag["nodes"][0], dag["nodes"][-1]]]}, "x-gh700-digest-dag"),
    ]
    for label, mutated, key in variants:
        probe = {**schema, key: mutated}
        anchor_key, _ = TRUSTED_REGISTRY_ANCHORS[key]
        probe[anchor_key] = anchor_digest(mutated, jcs)
        try:
            check_registry_anchors(probe, jcs, error)
        except Exception:
            mutations += 1
        else:
            raise error(f"registry anchor mutation accepted: {label}")
    return mutations


def _error_codes_accepted(schema, envelope_ref, method, codes, validate, pointer, error):
    """Which wire error codes the schema actually accepts for `method`."""
    envelope = pointer(schema, envelope_ref)
    accepted = set()
    for code in codes:
        probe = {"method": method, "error": {"code": code}}
        try:
            validate(probe, {"allOf": envelope.get("allOf", [])}, schema)
        except Exception:
            continue
        accepted.add(code)
    return accepted


def check_error_branches(schema, registry_rows, methods, validate, pointer, error):
    """Error envelopes are API branches, and their codes are registry-owned.

    Resolving whatever refs happen to be present certifies an API that cannot
    return valid client errors for some methods, and grouping methods into one
    conditional branch lets a method accept a code its registry row excludes.
    """
    root_branches = {item.get("$ref") for item in schema.get("oneOf", ()) if isinstance(item, dict)}
    for required in ("#/$defs/client_error", "#/$defs/control_error"):
        if required not in root_branches:
            raise error(f"root API union is missing the {required} branch")

    defs = schema["$defs"]
    wire_codes = tuple(defs["wire_error"]["properties"]["code"]["enum"])
    for name, surface in (("client_error", "client"), ("control_error", "control")):
        if tuple(defs[name]["properties"]["method"].get("enum", ())) != methods[surface]:
            raise error(f"{name}: open or reordered method enum")

    checked = 0
    for row in registry_rows:
        name = "client_error" if row["surface"] == "client" else "control_error"
        expected = set(row["error_codes"])
        unknown = expected - set(wire_codes)
        if unknown:
            raise error(f"{row['surface']}.{row['method']}: registry error codes outside wire_error: {sorted(unknown)}")
        accepted = _error_codes_accepted(schema, f"#/$defs/{name}", row["method"], wire_codes, validate, pointer, error)
        if accepted != expected:
            raise error(
                f"{row['surface']}.{row['method']}: schema error codes {sorted(accepted)} "
                f"do not match registry row {sorted(expected)}"
            )
        checked += 1
    return checked

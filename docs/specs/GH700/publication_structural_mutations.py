#!/usr/bin/env python3
"""Per-model structural mutations against the exact request/success schemas.

Binding-relation mutations only exercise cross-field agreement. Without a
structural pass, an exact wire schema can quietly lose `unevaluatedProperties`,
a required field, a closed method enum, or its forbidden-alias ban and still
certify every positive model. Each mutation here must be rejected by the exact
`request_ref`/`success_ref` the registry row names.
"""

import copy

EXTRA_KEY = "gh700_structural_probe"

# Pinned here, not read from the schema: sourcing the ban list from the same
# document it guards means deleting an alias also deletes the mutation that
# would have caught the deletion.
FORBIDDEN_ALIASES = (
    "append_auth",
    "bootstrap_manifest_approval",
    "delivery_auth",
    "kms_key_version",
    "max_accuracy_seconds",
    "policyBundleDigest",
    "request_nonce_digest",
    "transition_receipt_or_null",
)


def _required_paths(instance):
    """Top-level wire fields plus one level of body/result members."""
    for key in sorted(instance):
        yield (key,)
        child = instance[key]
        if key in ("body", "result") and isinstance(child, dict):
            for nested in sorted(child):
                yield (key, nested)


def _at(value, path):
    for step in path:
        value = value[step]
    return value


def _drop(value, path):
    mutated = copy.deepcopy(value)
    target = mutated
    for step in path[:-1]:
        target = target[step]
    del target[path[-1]]
    return mutated


def _set(value, path, replacement):
    mutated = copy.deepcopy(value)
    target = mutated
    for step in path[:-1]:
        target = target[step]
    target[path[-1]] = replacement
    return mutated


def structural_mutations(instance, side, methods, forbidden_aliases):
    """Yield (label, mutated_instance) pairs the exact schema must reject."""
    for path in _required_paths(instance):
        dotted = ".".join(str(step) for step in path)
        yield f"{side}.missing_{dotted}", _drop(instance, path)
        # `*_or_null` slots are declared nullable, so nulling them yields
        # another valid instance rather than a mutation the schema must reject.
        if _at(instance, path) is not None and not path[-1].endswith("_or_null"):
            yield f"{side}.null_{dotted}", _set(instance, path, None)

    yield f"{side}.extra", {**instance, EXTRA_KEY: "unexpected"}
    for container in ("body", "result"):
        if isinstance(instance.get(container), dict):
            yield f"{side}.extra_{container}", _set(instance, (container,), {**instance[container], EXTRA_KEY: "unexpected"})

    if "method" in instance:
        other = next(candidate for candidate in methods if candidate != instance["method"])
        yield f"{side}.wrong_method", {**instance, "method": other}

    for alias in sorted(forbidden_aliases):
        yield f"{side}.forbidden_alias_{alias}", {**instance, alias: "aliased"}


def check_structural_mutations(pairs, models, registry_by_method, schema, methods_by_surface, validate, pointer, error):
    """Every structural mutation must fail the exact request/success schema."""
    rejected = 0
    aliases = set(FORBIDDEN_ALIASES)
    if set(schema.get("x-gh700-forbidden-aliases", ())) != aliases:
        raise error(f"forbidden alias ban drifted from the pinned set {sorted(aliases)}")
    for model in models:
        request, response = pairs[model["model_id"]]
        row = registry_by_method[(model["surface"], model["method"])]
        methods = methods_by_surface[model["surface"]]
        for side, instance, ref in (
            ("request", request, row["request_ref"]),
            ("success", response, row["success_ref"]),
        ):
            target = pointer(schema, ref)
            for label, mutated in structural_mutations(instance, side, methods, aliases):
                try:
                    validate(mutated, target, schema)
                except Exception:
                    rejected += 1
                    continue
                raise error(f"{model['model_id']}: structural mutation accepted: {label}")
    if rejected == 0:
        raise error("structural mutation pass generated no rejections")
    return rejected

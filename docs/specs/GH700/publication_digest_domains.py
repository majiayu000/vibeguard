"""Schema-owned runtime-domain resolution for the GH700 digest formulas."""


def _walk(value):
    yield value
    children = value.values() if isinstance(value, dict) else value if isinstance(value, (list, tuple)) else ()
    for child in children:
        yield from _walk(child)


def allowed_domains(schema, node):
    declared = schema["x-gh700-digest-formulas"][node]["domain"]
    if declared == "exact branch domain in x-gh700-signing-preimages":
        return {item["domain"] for item in schema["x-gh700-signing-preimages"].values()}
    if declared == "none; raw-byte digest":
        return {None}
    if declared in {"receipt.receipt_version", "capsule_receipt.capsule_receipt_version"}:
        field = declared.split(".")[-1]
        return {item[field]["const"] for item in _walk(schema) if isinstance(item, dict) and isinstance(item.get(field), dict) and "const" in item[field]}
    if "{client|control}" in declared:
        return {declared.replace("{client|control}", surface) for surface in ("client", "control")}
    return set(declared.split(" or "))


def require_domain(schema, node, domain, error_type=ValueError):
    if domain not in allowed_domains(schema, node):
        raise error_type(f"{node}: runtime domain is not schema-owned")
    return domain

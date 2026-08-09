"""Dependency-free Ed25519 checks for the GH700 conformance vectors.

The fixed seeds below are RFC 8032 public test material, never production
credentials.  They are used only to materialize positive checked-in vectors;
verification always uses the public key pinned by the authority manifest.
"""

import hashlib


_Q = 2**255 - 19
_L = 2**252 + 27742317777372353535851937790883648493
_D = (-121665 * pow(121666, _Q - 2, _Q)) % _Q
_I = pow(2, (_Q - 1) // 4, _Q)

TEST_SEEDS = {
    "authorization": bytes.fromhex(
        "9d61b19deffd5a60ba844af492ec2cc4"
        "4449c5697b326919703bac031cae7f60"
    ),
    "release_identity": bytes.fromhex(
        "4ccd089b28ff96da9db6c346ec114e0f"
        "5b8a319f35aba624da8cf6ed4fb8a6fb"
    ),
}


def _xrecover(y):
    xx = (y * y - 1) * pow(_D * y * y + 1, _Q - 2, _Q) % _Q
    x = pow(xx, (_Q + 3) // 8, _Q)
    if (x * x - xx) % _Q:
        x = x * _I % _Q
    if x & 1:
        x = _Q - x
    return x


_BY = 4 * pow(5, _Q - 2, _Q) % _Q
_B = (_xrecover(_BY), _BY)


def _add(left, right):
    x1, y1 = left
    x2, y2 = right
    denominator = _D * x1 * x2 * y1 * y2
    return (
        (x1 * y2 + x2 * y1) * pow(1 + denominator, _Q - 2, _Q) % _Q,
        (y1 * y2 + x1 * x2) * pow(1 - denominator, _Q - 2, _Q) % _Q,
    )


def _scalar_mult(point, scalar):
    result = (0, 1)
    addend = point
    while scalar:
        if scalar & 1:
            result = _add(result, addend)
        addend = _add(addend, addend)
        scalar >>= 1
    return result


def _encode_point(point):
    x, y = point
    return (y | ((x & 1) << 255)).to_bytes(32, "little")


def _decode_point(raw):
    if len(raw) != 32:
        raise ValueError("Ed25519 point must be 32 bytes")
    encoded = int.from_bytes(raw, "little")
    y = encoded & ((1 << 255) - 1)
    if y >= _Q:
        raise ValueError("non-canonical Ed25519 point")
    x = _xrecover(y)
    sign = encoded >> 255
    if x == 0 and sign:
        raise ValueError("non-canonical Ed25519 x=0 sign bit")
    if (x & 1) != sign:
        x = _Q - x
    point = (x, y)
    if (-x * x + y * y - 1 - _D * x * x * y * y) % _Q:
        raise ValueError("Ed25519 point is not on the curve")
    if _encode_point(point) != raw:
        raise ValueError("non-canonical Ed25519 point encoding")
    return point


def _is_strict_subgroup_point(point):
    identity = (0, 1)
    return point != identity and _scalar_mult(point, _L) == identity


def _is_strict_public_key(raw):
    try:
        return _is_strict_subgroup_point(_decode_point(raw))
    except ValueError:
        return False


def public_key_from_seed(seed):
    digest = hashlib.sha512(seed).digest()
    scalar = int.from_bytes(
        bytes([digest[0] & 248]) + digest[1:31] + bytes([(digest[31] & 63) | 64]),
        "little",
    )
    return _encode_point(_scalar_mult(_B, scalar))


def sign_test_vector(role, message):
    seed = TEST_SEEDS[role]
    digest = hashlib.sha512(seed).digest()
    scalar = int.from_bytes(
        bytes([digest[0] & 248]) + digest[1:31] + bytes([(digest[31] & 63) | 64]),
        "little",
    )
    public_key = _encode_point(_scalar_mult(_B, scalar))
    nonce = int.from_bytes(hashlib.sha512(digest[32:] + message).digest(), "little") % _L
    encoded_r = _encode_point(_scalar_mult(_B, nonce))
    challenge = int.from_bytes(
        hashlib.sha512(encoded_r + public_key + message).digest(), "little"
    ) % _L
    return encoded_r + ((nonce + challenge * scalar) % _L).to_bytes(32, "little")


def verify(public_key, message, signature):
    if len(public_key) != 32 or len(signature) != 64:
        return False
    scalar = int.from_bytes(signature[32:], "little")
    if scalar >= _L:
        return False
    try:
        point_a = _decode_point(public_key)
        point_r = _decode_point(signature[:32])
    except ValueError:
        return False
    if not _is_strict_subgroup_point(point_a) or not _is_strict_subgroup_point(point_r):
        return False
    challenge = int.from_bytes(
        hashlib.sha512(signature[:32] + public_key + message).digest(), "little"
    ) % _L
    return _scalar_mult(_B, scalar) == _add(point_r, _scalar_mult(point_a, challenge))


def verify_or_materialize(
    container, signed_digest, label, role, manifest, decode_b64u, encode_b64u,
    derive, raw_digest, error_type=ValueError,
):
    """Verify a wire signature, deriving it only for positive test vectors."""
    if manifest.get("signature_algorithm") != "Ed25519":
        raise error_type(f"{label}: unsupported signature algorithm")
    expected_id = manifest[f"{role}_signing_key_id"]
    expected_material = manifest[f"{role}_signing_key_material_id"]
    public_key = decode_b64u(
        manifest[f"{role}_signing_public_key_b64u"], 32, f"{label}.public_key",
    )
    if not _is_strict_public_key(public_key):
        raise error_type(f"{label}: signing public key is non-canonical or not prime-order")
    if hashlib.sha256(public_key).hexdigest() != expected_material:
        raise error_type(f"{label}: signing key material id does not identify the public key")
    if container.get("signing_key_id") != expected_id:
        raise error_type(f"{label}: signing_key_id is not the active {role} key")
    if container.get("signing_key_material_id") != expected_material:
        raise error_type(f"{label}: signing_key_material_id is not the active {role} key")
    if not isinstance(signed_digest, str) or not signed_digest.startswith("sha256:"):
        raise error_type(f"{label}: signed digest is not canonical")
    message = bytes.fromhex(signed_digest.removeprefix("sha256:"))
    signature_value = container.get("signature_b64u")
    if signature_value == {"$derive": "signature_b64u"}:
        signature_value = encode_b64u(sign_test_vector(role, message))
        container["signature_b64u"] = signature_value
    raw_signature = decode_b64u(signature_value, 64, f"{label}.signature_b64u")
    if not verify(public_key, message, raw_signature):
        raise error_type(f"{label}: Ed25519 signature verification failed")
    derive(container, "signature_digest", raw_digest(raw_signature), label)


def self_test(error_type=ValueError):
    checked = 0
    known_answers = (
        (
            "authorization", b"",
            "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
            "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
            "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
        ),
        (
            "release_identity", bytes.fromhex("72"),
            "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
            "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da"
            "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aee"
            "b00d291612bb0c00",
        ),
    )
    for role, message, public_hex, signature_hex in known_answers:
        public_key = bytes.fromhex(public_hex)
        signature = bytes.fromhex(signature_hex)
        if not _is_strict_public_key(public_key):
            raise error_type(f"{role}: RFC 8032 public key rejected by manifest gate")
        if public_key_from_seed(TEST_SEEDS[role]) != public_key:
            raise error_type(f"{role}: RFC 8032 public key KAT mismatch")
        if sign_test_vector(role, message) != signature:
            raise error_type(f"{role}: RFC 8032 signature KAT mismatch")
        if not verify(public_key, message, signature):
            raise error_type(f"{role}: RFC 8032 signature KAT rejected")
        mutated = bytes([signature[0] ^ 1]) + signature[1:]
        if verify(public_key, message, mutated):
            raise error_type(f"{role}: one-bit Ed25519 mutation accepted")
        other_role = "release_identity" if role == "authorization" else "authorization"
        if verify(public_key_from_seed(TEST_SEEDS[other_role]), message, signature):
            raise error_type(f"{role}: wrong Ed25519 key accepted")
        checked += 6

    identity = b"\x01" + b"\x00" * 31
    order_four = b"\x00" * 32
    noncanonical_identity = identity[:-1] + b"\x80"
    canonical_key = bytes.fromhex(known_answers[0][2])
    canonical_signature = bytes.fromhex(known_answers[0][3])
    rejection_vectors = (
        (identity, b"anything", identity + b"\x00" * 32, "identity public key/R"),
        (order_four, b"anything", identity + b"\x00" * 32, "small-order public key"),
        (noncanonical_identity, b"anything", identity + b"\x00" * 32, "x=0 sign bit"),
        (canonical_key, b"", identity + b"\x00" * 32, "identity R"),
        (canonical_key, b"", order_four + b"\x00" * 32, "small-order R"),
        (canonical_key, b"", canonical_signature[:32] + _L.to_bytes(32, "little"), "S >= L"),
    )
    for weak_key, label in (
        (identity, "identity public key"),
        (order_four, "small-order public key"),
        (noncanonical_identity, "x=0 sign-bit public key"),
    ):
        if _is_strict_public_key(weak_key):
            raise error_type(f"manifest gate accepted {label}")
        checked += 1
    for public_key, message, signature, label in rejection_vectors:
        if verify(public_key, message, signature):
            raise error_type(f"rejected Ed25519 vector accepted: {label}")
        checked += 1
    return checked

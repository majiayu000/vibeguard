"""Shared errors for read-only GitHub evidence adapters."""

from typing import Any


class EvidenceError(ValueError):
    """Raised when GitHub evidence cannot be collected or normalized."""


def json_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise EvidenceError(f"{label} must be a JSON object")
    return value


def json_array(value: Any, label: str) -> list[Any]:
    if not isinstance(value, list):
        raise EvidenceError(f"{label} must be a JSON array")
    return value

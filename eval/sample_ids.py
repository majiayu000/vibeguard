"""Shared eval sample id validation."""

from __future__ import annotations

import re

SAFE_SAMPLE_ID_PATTERN = r"[A-Za-z0-9][A-Za-z0-9_.-]*"
SAFE_SAMPLE_ID_RE = re.compile(f"^{SAFE_SAMPLE_ID_PATTERN}$")


def is_safe_sample_id(sample_id: str) -> bool:
    return bool(SAFE_SAMPLE_ID_RE.fullmatch(sample_id))

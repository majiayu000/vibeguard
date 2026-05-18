"""Structured scorer parsing for eval model replies."""

from __future__ import annotations

import json
import re
from typing import Any

CONFIDENCE_SCORES = {
    "low": 0.33,
    "medium": 0.66,
    "high": 0.90,
}


class ScorerParseError(ValueError):
    """Raised when the model reply is not a valid structured scorer verdict."""


def parse_confidence(reply: str) -> str | None:
    match = re.search(r"\bconfidence\s*[:=-]\s*(low|medium|high)\b", reply, re.IGNORECASE)
    if not match:
        return None
    return match.group(1).lower()


def parse_scorer_output(reply: str) -> dict[str, Any]:
    payload = _extract_json_object(reply)
    try:
        parsed = json.loads(payload)
    except json.JSONDecodeError as exc:
        raise ScorerParseError(f"invalid JSON scorer output: {exc.msg}") from exc

    if not isinstance(parsed, dict):
        raise ScorerParseError("structured scorer output must be a JSON object")
    if not isinstance(parsed.get("detected"), bool):
        raise ScorerParseError("structured scorer output requires boolean detected")

    rule_ids = parsed.get("rule_ids", [])
    if not isinstance(rule_ids, list) or not all(isinstance(rule_id, str) for rule_id in rule_ids):
        raise ScorerParseError("structured scorer output requires rule_ids as a list of strings")

    confidence = parsed.get("confidence")
    if confidence is not None:
        if not isinstance(confidence, str) or confidence.lower() not in CONFIDENCE_SCORES:
            raise ScorerParseError("confidence must be low, medium, high, or omitted")
        confidence = confidence.lower()

    reason = parsed.get("reason", "")
    if reason is not None and not isinstance(reason, str):
        raise ScorerParseError("reason must be a string when supplied")

    return {
        "detected": parsed["detected"],
        "rule_ids": [rule_id.strip().upper() for rule_id in rule_ids if rule_id.strip()],
        "confidence": confidence,
        "reason": reason or "",
    }


def _extract_json_object(reply: str) -> str:
    stripped = reply.strip()
    if stripped.startswith("```"):
        stripped = re.sub(r"^```(?:json)?\s*", "", stripped, flags=re.IGNORECASE)
        stripped = re.sub(r"\s*```$", "", stripped)
    if stripped.startswith("{") and stripped.endswith("}"):
        return stripped

    start = stripped.find("{")
    end = stripped.rfind("}")
    if start == -1 or end == -1 or end <= start:
        raise ScorerParseError("structured scorer output must contain one JSON object")
    return stripped[start : end + 1]

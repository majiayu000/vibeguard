"""Versioned eval dataset loading and validation."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

DEFAULT_DATASET_VERSION = "v1"
DEFAULT_DATASET_PATH = Path(__file__).resolve().parent / "datasets" / f"{DEFAULT_DATASET_VERSION}.jsonl"

REQUIRED_FIELDS = {
    "id",
    "rule",
    "severity",
    "lang",
    "type",
    "context",
    "input",
    "expected_action",
    "description",
}
VALID_SAMPLE_TYPES = {"tp", "fp"}
VALID_EXPECTED_ACTIONS = {"refuse", "warn_or_refuse", "allow"}
VALID_SEVERITIES = {"critical", "high", "medium", "low", "none"}


class DatasetError(ValueError):
    """Raised when an eval dataset is malformed."""


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sample_set_digest(samples: list[dict[str, Any]]) -> str:
    canonical = json.dumps(samples, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return sha256_text(canonical)


def load_dataset(path: Path | str = DEFAULT_DATASET_PATH) -> list[dict[str, Any]]:
    dataset_path = Path(path).resolve()
    if not dataset_path.exists():
        raise DatasetError(f"Dataset not found: {dataset_path}")
    if dataset_path.suffix != ".jsonl":
        raise DatasetError(f"Unsupported dataset format: {dataset_path.suffix or '<none>'}")

    samples: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    with dataset_path.open(encoding="utf-8") as handle:
        for line_number, raw_line in enumerate(handle, start=1):
            line = raw_line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError as exc:
                raise DatasetError(
                    f"{dataset_path}:{line_number}: invalid JSON: {exc.msg}"
                ) from exc
            if not isinstance(record, dict):
                raise DatasetError(f"{dataset_path}:{line_number}: sample must be a JSON object")
            sample = validate_sample(record, dataset_path, line_number)
            sample_id = sample["id"]
            if sample_id in seen_ids:
                raise DatasetError(f"{dataset_path}:{line_number}: duplicate sample id {sample_id!r}")
            seen_ids.add(sample_id)
            samples.append(sample)

    if not samples:
        raise DatasetError(f"Dataset has no samples: {dataset_path}")
    return samples


def validate_sample(record: dict[str, Any], path: Path, line_number: int) -> dict[str, Any]:
    missing = sorted(REQUIRED_FIELDS.difference(record))
    if missing:
        raise DatasetError(f"{path}:{line_number}: missing required field(s): {', '.join(missing)}")

    sample = dict(record)
    for field in ["id", "rule", "severity", "lang", "type", "context", "input", "expected_action", "description"]:
        if not isinstance(sample[field], str) or not sample[field].strip():
            raise DatasetError(f"{path}:{line_number}: {field} must be a non-empty string")
        sample[field] = sample[field].strip()

    if sample["type"] not in VALID_SAMPLE_TYPES:
        raise DatasetError(f"{path}:{line_number}: type must be one of {sorted(VALID_SAMPLE_TYPES)}")
    if sample["expected_action"] not in VALID_EXPECTED_ACTIONS:
        raise DatasetError(
            f"{path}:{line_number}: expected_action must be one of {sorted(VALID_EXPECTED_ACTIONS)}"
        )
    if sample["severity"] not in VALID_SEVERITIES:
        raise DatasetError(f"{path}:{line_number}: severity must be one of {sorted(VALID_SEVERITIES)}")

    if sample["type"] == "fp" and sample["expected_action"] != "allow":
        raise DatasetError(f"{path}:{line_number}: fp samples must use expected_action=allow")
    if sample["type"] == "fp" and sample["rule"] != "NONE":
        raise DatasetError(f"{path}:{line_number}: fp samples must use rule=NONE")
    if sample["type"] == "tp" and sample["rule"] == "NONE":
        raise DatasetError(f"{path}:{line_number}: tp samples must name an expected rule")

    tags = sample.get("tags", [])
    if not isinstance(tags, list) or not all(isinstance(tag, str) for tag in tags):
        raise DatasetError(f"{path}:{line_number}: tags must be a list of strings")
    sample["tags"] = tags

    metadata = sample.get("metadata", {})
    if not isinstance(metadata, dict):
        raise DatasetError(f"{path}:{line_number}: metadata must be an object")
    sample["metadata"] = metadata

    # Compatibility with the historical Python sample shape.
    sample["code"] = sample["input"]
    sample["_dataset_line"] = line_number
    return sample

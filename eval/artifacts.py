"""Immutable eval run artifact helpers."""

from __future__ import annotations

import json
import subprocess
import time
from pathlib import Path
from typing import Any

try:
    from .sample_ids import SAFE_SAMPLE_ID_PATTERN, is_safe_sample_id
except ImportError:
    from sample_ids import SAFE_SAMPLE_ID_PATTERN, is_safe_sample_id

DEFAULT_RUNS_DIR = Path(__file__).resolve().parent / "runs"
DEFAULT_INDEX_NAME = "index.jsonl"


class RunSummaryError(ValueError):
    """Raised when an eval run summary index is malformed."""


class ArtifactPathError(ValueError):
    """Raised when an eval artifact path would leave its run directory."""


def utc_timestamp() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def current_commit(short: bool = True) -> str:
    args = ["git", "rev-parse", "--short", "HEAD"] if short else ["git", "rev-parse", "HEAD"]
    try:
        result = subprocess.run(
            args,
            cwd=Path(__file__).resolve().parents[1],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return "unknown"
    return result.stdout.strip() or "unknown"


def build_run_dir(
    artifact_root: Path | str = DEFAULT_RUNS_DIR,
    *,
    timestamp: str | None = None,
    commit: str | None = None,
) -> Path:
    root = Path(artifact_root).resolve()
    run_timestamp = timestamp or time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    run_commit = commit or current_commit(short=True)
    candidate = root / f"{run_timestamp}-{run_commit}"
    suffix = 2
    while candidate.exists():
        candidate = root / f"{run_timestamp}-{run_commit}-{suffix}"
        suffix += 1
    return candidate


def write_run_artifacts(
    run_dir: Path | str,
    *,
    metadata: dict[str, Any],
    samples: list[dict[str, Any]],
    results: list[dict[str, Any]],
) -> Path:
    output_dir = Path(run_dir)
    output_dir.mkdir(parents=True, exist_ok=False)
    sample_dir = output_dir / "samples"
    sample_dir.mkdir()

    result_by_id = {result.get("id"): result for result in results}
    for sample in samples:
        sample_id = sample["id"]
        sample_payload = {
            "sample": _clean_sample(sample),
            "result": result_by_id.get(sample_id),
        }
        sample_path = _sample_artifact_path(sample_dir, sample_id)
        sample_path.write_text(
            json.dumps(sample_payload, indent=2, ensure_ascii=False, sort_keys=True),
            encoding="utf-8",
        )

    results_path = output_dir / "results.json"
    results_path.write_text(
        json.dumps(
            {
                "metadata": metadata,
                "samples": [_clean_sample(sample) for sample in samples],
                "results": results,
            },
            indent=2,
            ensure_ascii=False,
            sort_keys=True,
        ),
        encoding="utf-8",
    )
    return results_path


def _sample_artifact_path(sample_dir: Path, sample_id: Any) -> Path:
    if not isinstance(sample_id, str) or not is_safe_sample_id(sample_id):
        raise ArtifactPathError(f"unsafe sample id {sample_id!r}; expected {SAFE_SAMPLE_ID_PATTERN!r}")

    sample_root = sample_dir.resolve()
    candidate = (sample_root / f"{sample_id}.json").resolve()
    try:
        candidate.relative_to(sample_root)
    except ValueError as exc:
        raise ArtifactPathError(f"sample artifact path escaped samples dir: {candidate}") from exc
    return candidate


def append_run_summary(
    artifact_root: Path | str = DEFAULT_RUNS_DIR,
    summary: dict[str, Any] | None = None,
) -> Path:
    if summary is None:
        raise RunSummaryError("summary record is required")
    index_path = Path(artifact_root).resolve() / DEFAULT_INDEX_NAME
    index_path.parent.mkdir(parents=True, exist_ok=True)
    with index_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(summary, ensure_ascii=False, sort_keys=True) + "\n")
    return index_path


def load_run_summaries(index_path: Path | str) -> list[dict[str, Any]]:
    path = Path(index_path)
    if not path.exists():
        return []

    records: list[dict[str, Any]] = []
    with path.open(encoding="utf-8") as handle:
        for line_number, raw_line in enumerate(handle, start=1):
            line = raw_line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError as exc:
                raise RunSummaryError(f"{path}:{line_number}: invalid JSON: {exc.msg}") from exc
            if not isinstance(record, dict):
                raise RunSummaryError(f"{path}:{line_number}: summary record must be a JSON object")
            records.append(record)
    return records


def _clean_sample(sample: dict[str, Any]) -> dict[str, Any]:
    return {
        key: value
        for key, value in sample.items()
        if not key.startswith("_") and key != "code"
    }

"""Immutable eval run artifact helpers."""

from __future__ import annotations

import json
import subprocess
import time
from pathlib import Path
from typing import Any

DEFAULT_RUNS_DIR = Path(__file__).resolve().parent / "runs"


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
        (sample_dir / f"{sample_id}.json").write_text(
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


def _clean_sample(sample: dict[str, Any]) -> dict[str, Any]:
    return {
        key: value
        for key, value in sample.items()
        if not key.startswith("_") and key != "code"
    }

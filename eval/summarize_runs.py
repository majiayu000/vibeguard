#!/usr/bin/env python3
"""Read eval/runs/index.jsonl and print compact run summaries."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from artifacts import DEFAULT_INDEX_NAME, DEFAULT_RUNS_DIR, RunSummaryError, load_run_summaries


def short_digest(value: Any, length: int = 12) -> str:
    text = str(value or "")
    return text[:length] if text else "unknown"


def percent(value: Any) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, (int, float)):
        return f"{value:.1f}%"
    return str(value)


def count_slice_failures(record: dict[str, Any]) -> int:
    slice_failures = record.get("slice_failures", [])
    return len(slice_failures) if isinstance(slice_failures, list) else 0


def format_record(record: dict[str, Any]) -> str:
    kind = record.get("kind", "unknown")
    timestamp = record.get("timestamp", "unknown")
    commit = short_digest(record.get("commit"), length=8)
    dataset = short_digest(record.get("dataset_digest"))
    artifact_path = record.get("artifact_path", "")

    if kind == "behavior":
        return (
            f"{timestamp} behavior deterministic commit={commit} dataset={dataset} "
            f"verdict={record.get('verdict', 'unknown')} "
            f"pass={percent(record.get('pass_rate'))} "
            f"coverage={percent(record.get('coverage_rate'))} "
            f"slice_failures={count_slice_failures(record)} "
            f"failures={record.get('failure_count', 'unknown')} "
            f"artifact={artifact_path}"
        )

    if kind == "model":
        rule_digest = short_digest(record.get("rule_digest"))
        return (
            f"{timestamp} model model-backed model={record.get('model', 'unknown')} "
            f"commit={commit} dataset={dataset} rules={rule_digest} "
            f"detection={percent(record.get('detection_rate'))} "
            f"false_positive={percent(record.get('false_positive_rate'))} "
            f"skipped={record.get('skipped_count', 'unknown')} "
            f"ece={percent(record.get('ece'))} "
            f"artifact={artifact_path}"
        )

    return (
        f"{timestamp} {kind} score_type={record.get('score_type', 'unknown')} "
        f"commit={commit} dataset={dataset} artifact={artifact_path}"
    )


def select_records(records: list[dict[str, Any]], *, kind: str | None, last: int) -> list[dict[str, Any]]:
    filtered = [record for record in records if kind is None or record.get("kind") == kind]
    return filtered[-last:]


def main() -> int:
    parser = argparse.ArgumentParser(description="Summarize recent VibeGuard eval runs")
    parser.add_argument("--runs-dir", default=str(DEFAULT_RUNS_DIR), help="Directory containing index.jsonl")
    parser.add_argument("--last", type=int, default=10, help="Number of recent records to display")
    parser.add_argument("--kind", choices=["behavior", "model"], help="Only display one eval summary kind")
    parser.add_argument("--json", action="store_true", help="Emit selected records as JSON")
    args = parser.parse_args()

    if args.last < 1:
        parser.error("--last must be at least 1")

    index_path = Path(args.runs_dir).resolve() / DEFAULT_INDEX_NAME
    try:
        records = load_run_summaries(index_path)
    except RunSummaryError as exc:
        sys.stderr.write(f"{exc}\n")
        return 2

    selected = select_records(records, kind=args.kind, last=args.last)
    if args.json:
        sys.stdout.write(json.dumps(selected, indent=2, ensure_ascii=False, sort_keys=True) + "\n")
        return 0

    if not selected:
        sys.stdout.write(f"No eval run summaries found at {index_path}\n")
        return 0

    sys.stdout.write(f"Eval run summaries ({len(selected)} shown, index: {index_path})\n")
    for record in selected:
        sys.stdout.write(format_record(record) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

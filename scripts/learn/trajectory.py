#!/usr/bin/env python3
"""Record and preview W-37 success/failure Learn trajectories."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path
from typing import Any

from triage_state import utc_now


DEFAULT_TRAJECTORY_STORE = Path.home() / ".vibeguard" / "learn-trajectories.jsonl"


class LearnTrajectoryError(ValueError):
    """Raised when Learn trajectory data would violate W-37."""


def default_trajectory_store() -> Path:
    return Path(os.environ.get("VIBEGUARD_LEARN_TRAJECTORY_FILE", DEFAULT_TRAJECTORY_STORE))


def learn_trajectory_hash(payload: dict[str, Any]) -> str:
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    return "traj:" + hashlib.sha256(encoded.encode("utf-8")).hexdigest()[:16]


def append_trajectory_record(path: Path, record: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True) + "\n")


def read_trajectory_records(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    records: list[dict[str, Any]] = []
    with path.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(item, dict):
                records.append(item)
    return records


def iso_now() -> str:
    return utc_now().strftime("%Y-%m-%dT%H:%M:%SZ")


def build_record(args: argparse.Namespace) -> dict[str, Any]:
    if args.outcome == "success" and not args.low_friction:
        raise LearnTrajectoryError("successful trajectories must set --low-friction")
    base = {
        "schema_version": 1,
        "task_class": args.task_class,
        "outcome": args.outcome,
        "evidence": args.evidence,
        "signal_id": args.signal_id,
    }
    record = {
        **base,
        "trajectory_id": learn_trajectory_hash(base),
        "ts": iso_now(),
        "outcome_flags": {
            "success": args.outcome == "success",
            "failure": args.outcome == "failure",
            "low_friction": bool(args.low_friction),
        },
        "verification_commands": args.verification_command,
        "failure_lesson": args.failure_lesson,
    }
    return record


def records_for_task(records: list[dict[str, Any]], task_class: str) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    matching = [record for record in records if record.get("task_class") == task_class]
    successes = [record for record in matching if record.get("outcome") == "success"]
    failures = [record for record in matching if record.get("outcome") == "failure"]
    return successes, failures


def preview_task(path: Path, task_class: str, success_only: bool) -> dict[str, Any]:
    successes, failures = records_for_task(read_trajectory_records(path), task_class)
    if success_only and failures:
        raise LearnTrajectoryError(
            "success-only retrieval is rejected because failure lessons exist for this task class"
        )
    return {
        "command": "learn",
        "mode": "trajectory_preview",
        "schema_version": 1,
        "task_class": task_class,
        "success_trajectories": successes,
        "failure_trajectories": [] if success_only else failures,
        "combined_evidence_available": bool(successes and failures and not success_only),
    }


def build_trajectory_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Record or preview W-37 Learn trajectories.")
    parser.add_argument("--store", type=Path, default=default_trajectory_store())
    sub = parser.add_subparsers(dest="command", required=True)

    record = sub.add_parser("record")
    record.add_argument("--task-class", required=True)
    record.add_argument("--outcome", choices=["success", "failure"], required=True)
    record.add_argument("--evidence", required=True)
    record.add_argument("--signal-id")
    record.add_argument("--verification-command", action="append", default=[])
    record.add_argument("--failure-lesson")
    record.add_argument("--low-friction", action="store_true")

    preview = sub.add_parser("preview")
    preview.add_argument("--task-class", required=True)
    preview.add_argument("--success-only", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_trajectory_parser().parse_args(argv)
    try:
        if args.command == "record":
            output = build_record(args)
            append_trajectory_record(args.store, output)
        else:
            output = preview_task(args.store, args.task_class, args.success_only)
    except LearnTrajectoryError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    sys.stdout.write(json.dumps(output, indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

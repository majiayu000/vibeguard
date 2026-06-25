#!/usr/bin/env python3
"""Append explicit Learn signal triage transitions."""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


STATES = {"new", "adopted", "skipped", "stale", "snoozed", "verified", "regressed"}


def default_state_file() -> Path:
    return Path(os.environ.get("VIBEGUARD_LEARN_STATE_FILE", Path.home() / ".vibeguard" / "learn-state.jsonl"))


def utc_now() -> datetime:
    fixed = os.environ.get("_VIBEGUARD_TEST_NOW")
    if fixed:
        return datetime.fromisoformat(fixed.replace("Z", "+00:00")).astimezone(timezone.utc)
    return datetime.now(timezone.utc)


def read_latest_states(path: Path) -> dict[str, str]:
    states: dict[str, str] = {}
    if not path.exists():
        return states
    with path.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            signal_id = record.get("signal_id")
            to_state = record.get("to")
            if isinstance(signal_id, str) and to_state in STATES:
                states[signal_id] = to_state
    return states


def append_transition(path: Path, record: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True) + "\n")


def build_triage_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Append a Learn triage state transition.")
    parser.add_argument("--state-file", type=Path, default=default_state_file())
    sub = parser.add_subparsers(dest="command", required=True)
    for command, to_state in (("adopt", "adopted"), ("skip", "skipped"), ("snooze", "snoozed")):
        item = sub.add_parser(command)
        item.set_defaults(to_state=to_state)
        item.add_argument("signal_id")
        item.add_argument("--reason", required=True)
        if command == "snooze":
            item.add_argument("--days", type=int, required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_triage_parser().parse_args(argv)
    if args.command == "snooze" and args.days <= 0:
        print("--days must be > 0", file=sys.stderr)
        return 2

    now = utc_now()
    latest = read_latest_states(args.state_file)
    record: dict[str, Any] = {
        "schema_version": 1,
        "signal_id": args.signal_id,
        "from": latest.get(args.signal_id, "new"),
        "to": args.to_state,
        "reason": args.reason,
        "ts": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    if args.command == "snooze":
        record["until"] = (now + timedelta(days=args.days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    append_transition(args.state_file, record)
    sys.stdout.write(json.dumps(record, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

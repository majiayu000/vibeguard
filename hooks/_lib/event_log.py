#!/usr/bin/env python3
"""Shared JSONL event-log helpers.

Event logs are written by shell hooks and may contain malformed UTF-8 if an
upstream shell truncates a multibyte string. Readers must tolerate that
without crashing and should skip only truly broken JSON records.
"""

from __future__ import annotations

import json
from datetime import datetime
from typing import BinaryIO, Iterator


def parse_ts(ts: object) -> datetime | None:
    if not isinstance(ts, str) or not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None


def iter_events_from_stream(
    stream: BinaryIO,
    *,
    since: datetime | None = None,
) -> Iterator[dict]:
    for raw_line in stream:
        line = raw_line.decode("utf-8", errors="replace").strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict):
            continue

        if since is not None:
            event_ts = parse_ts(event.get("ts"))
            if event_ts is None or event_ts < since:
                continue
            event = dict(event)
            event["_parsed_ts"] = event_ts

        yield event


def load_events_from_file(
    log_file: str,
    *,
    since: datetime | None = None,
) -> list[dict]:
    with open(log_file, "rb") as f:
        return list(iter_events_from_stream(f, since=since))

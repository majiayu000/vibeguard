#!/usr/bin/env python3
"""Generate a redacted VibeGuard false-positive report."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


SECRET_PATTERNS = [
    re.compile(r"(?i)\b(token|secret|password|api[_-]?key)\s*[:=]\s*[^\s,;]+"),
    re.compile(r"\bgh[pousr]_[A-Za-z0-9_]{8,}\b"),
    re.compile(r"\bsk-[A-Za-z0-9_-]{8,}\b"),
    re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{8,}\b"),
]


def redact(text: str) -> str:
    redacted = text
    for pattern in SECRET_PATTERNS:
        redacted = pattern.sub(lambda match: _redact_match(match), redacted)
    return redacted


def _redact_match(match: re.Match[str]) -> str:
    if match.lastindex:
        return f"{match.group(1)}=<redacted>"
    return "<redacted-secret>"


def load_event(path: Path, event_id: str) -> dict[str, Any] | None:
    if not path.is_file():
        raise SystemExit(f"event log does not exist: {path}")

    selected: dict[str, Any] | None = None
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for raw_line in handle:
            raw_line = raw_line.strip()
            if not raw_line:
                continue
            try:
                row = json.loads(raw_line)
            except json.JSONDecodeError:
                continue
            if not isinstance(row, dict):
                continue
            if event_matches(row, event_id):
                selected = row
    return selected


def event_matches(row: dict[str, Any], event_id: str) -> bool:
    return any(
        row.get(field) == event_id
        for field in ("event_id", "code", "rule_id")
    ) or event_id in str(row.get("reason", "")) or event_id in str(row.get("detail", ""))


def value_from(args_value: str | None, event: dict[str, Any] | None, *fields: str) -> str:
    if args_value:
        return redact(args_value)
    if event:
        for field in fields:
            value = event.get(field)
            if isinstance(value, str) and value:
                return redact(value)
    return "unknown"


def build_payload(args: argparse.Namespace) -> dict[str, str]:
    event = load_event(Path(args.event_log), args.event_id) if args.event_log else None
    context = value_from(
        args.remediation_context,
        event,
        "reason",
        "detail",
    )
    return {
        "event_id": args.event_id,
        "code": value_from(args.code, event, "event_id", "code"),
        "hook": value_from(args.hook, event, "hook"),
        "rule_id": value_from(args.rule, event, "rule_id"),
        "path": value_from(args.path, event, "path", "detail"),
        "decision": value_from(args.decision, event, "decision"),
        "status": value_from(args.status, event, "status"),
        "remediation_context": context,
    }


def render_markdown(payload: dict[str, str]) -> str:
    lines = [
        "# False positive report",
        "",
        f"- event_id: `{payload['event_id']}`",
        f"- code: `{payload['code']}`",
        f"- hook: `{payload['hook']}`",
        f"- rule_id: `{payload['rule_id']}`",
        f"- path: `{payload['path']}`",
        f"- decision: `{payload['decision']}`",
        f"- status: `{payload['status']}`",
        "",
        "## Remediation context",
        "",
        payload["remediation_context"],
        "",
        "## Lifecycle routing",
        "",
        "Record the triage verdict with `python3 scripts/precision-tracker.py --record fp <RULE-ID> --context <NOTE>` after confirming this is a false positive.",
    ]
    return "\n".join(lines)


def parse_report_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate a redacted VibeGuard false-positive report."
    )
    parser.add_argument("event_id", help="Stable event id, code, or rule id from hook output.")
    parser.add_argument("--event-log", help="events.jsonl file to inspect.")
    parser.add_argument("--hook", help="Hook name, such as post-edit-guard.")
    parser.add_argument("--rule", help="Rule id, such as RS-03.")
    parser.add_argument("--path", help="Project-relative path that triggered the finding.")
    parser.add_argument("--code", help="Stable VG-* code from hook output.")
    parser.add_argument("--decision", help="Hook decision, such as warn or block.")
    parser.add_argument("--status", help="Hook status, such as warn or timeout.")
    parser.add_argument("--remediation-context", help="Why this looks like a false positive.")
    parser.add_argument(
        "--format",
        choices=["markdown", "json"],
        default="markdown",
        help="Output format.",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_report_args(argv)
    payload = build_payload(args)
    if args.format == "json":
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(render_markdown(payload))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""Normalize Codex apply_patch hook payloads for VibeGuard's file hooks.

Codex sends apply_patch hooks with a single ``tool_input.command`` string. The
Claude-facing VibeGuard hooks expect Edit/Write-shaped payloads with
``tool_input.file_path`` and either ``new_string`` or ``content``. This adapter
fans a patch out into per-file payloads for the wrapped hook.
"""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass, field
from typing import Any


@dataclass
class PatchChange:
    kind: str
    path: str
    new_path: str | None = None
    added_lines: list[str] = field(default_factory=list)


def _finish(changes: list[PatchChange], current: PatchChange | None) -> None:
    if current is not None:
        changes.append(current)


def parse_apply_patch(command: str) -> list[PatchChange]:
    changes: list[PatchChange] = []
    current: PatchChange | None = None

    for line in command.splitlines():
        if line.startswith("*** Add File: "):
            _finish(changes, current)
            current = PatchChange("add", line.removeprefix("*** Add File: ").strip())
            continue
        if line.startswith("*** Update File: "):
            _finish(changes, current)
            current = PatchChange("update", line.removeprefix("*** Update File: ").strip())
            continue
        if line.startswith("*** Delete File: "):
            _finish(changes, current)
            current = PatchChange("delete", line.removeprefix("*** Delete File: ").strip())
            continue
        if current is None:
            continue
        if line.startswith("*** Move to: "):
            current.new_path = line.removeprefix("*** Move to: ").strip()
            continue
        if line.startswith("+"):
            current.added_lines.append(line[1:])

    _finish(changes, current)
    return changes


def _event_name(payload: dict[str, Any]) -> str:
    event = payload.get("hook_event_name")
    return event if isinstance(event, str) else ""


def _is_apply_patch(payload: dict[str, Any]) -> bool:
    tool_name = payload.get("tool_name")
    if tool_name == "apply_patch":
        return True
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return False
    command = tool_input.get("command")
    return isinstance(command, str) and command.lstrip().startswith("*** Begin Patch")


def _command(payload: dict[str, Any]) -> str:
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return ""
    command = tool_input.get("command")
    return command if isinstance(command, str) else ""


def _with_tool_input(payload: dict[str, Any], tool_name: str, tool_input: dict[str, Any]) -> dict[str, Any]:
    normalized = dict(payload)
    normalized["tool_name"] = tool_name
    normalized["tool_input"] = tool_input
    return normalized


def normalized_payloads(hook_name: str, payload: dict[str, Any]) -> list[dict[str, Any]]:
    event = _event_name(payload)
    if event not in {"PreToolUse", "PermissionRequest", "PostToolUse"}:
        return [payload]
    if not _is_apply_patch(payload):
        return [payload]

    changes = parse_apply_patch(_command(payload))
    if not changes:
        return [payload]

    if "pre-write" in hook_name or "post-write" in hook_name:
        result = []
        for change in changes:
            if change.kind != "add":
                continue
            result.append(
                _with_tool_input(
                    payload,
                    "Write",
                    {"file_path": change.path, "content": "\n".join(change.added_lines)},
                )
            )
        return result

    if "pre-edit" in hook_name or "post-edit" in hook_name:
        result = []
        for change in changes:
            if change.kind == "add":
                continue
            file_path = change.new_path if change.kind == "update" and change.new_path else change.path
            result.append(
                _with_tool_input(
                    payload,
                    "Edit",
                    {
                        "file_path": file_path,
                        "old_string": "",
                        "new_string": "\n".join(change.added_lines),
                    },
                )
            )
        return result

    if "post-build-check" in hook_name:
        result = []
        for change in changes:
            file_path = change.new_path or change.path
            tool_name = "Write" if change.kind == "add" else "Edit"
            result.append(_with_tool_input(payload, tool_name, {"file_path": file_path}))
        return result

    return [payload]


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: codex_apply_patch_adapter.py <hook-name>", file=sys.stderr)
        return 2
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        print(raw)
        return 0
    if not isinstance(payload, dict):
        print(raw)
        return 0

    for item in normalized_payloads(sys.argv[1], payload):
        print(json.dumps(item, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

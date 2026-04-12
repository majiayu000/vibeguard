"""Tests for codex_hooks_json.py — focuses on idempotency of cmd_upsert_vibeguard."""
from __future__ import annotations

import argparse
import json
import tempfile
from pathlib import Path

import pytest

# Allow import from the same directory.
import sys
sys.path.insert(0, str(Path(__file__).parent))

from codex_hooks_json import (
    MANAGED_SPECS,
    cmd_upsert_vibeguard,
)


def _make_args(hooks_file: str, wrapper: str) -> argparse.Namespace:
    ns = argparse.Namespace()
    ns.hooks_file = hooks_file
    ns.wrapper = wrapper
    return ns


def _count_entries(data: dict, event: str, command: str) -> int:
    """Count how many hook entries with the given command exist under the event."""
    hooks = data.get("hooks", {})
    entries = hooks.get(event, [])
    count = 0
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        for hook in entry.get("hooks", []):
            if isinstance(hook, dict) and hook.get("command") == command:
                count += 1
    return count


class TestUpsertIdempotencyStandardWrapper:
    """Wrapper containing run-hook-codex.sh — the existing happy path."""

    def test_double_upsert_no_duplicates(self, tmp_path: Path) -> None:
        hooks_file = tmp_path / "hooks.json"
        wrapper = str(tmp_path / "run-hook-codex.sh")
        args = _make_args(str(hooks_file), wrapper)

        cmd_upsert_vibeguard(args)
        cmd_upsert_vibeguard(args)

        data = json.loads(hooks_file.read_text())
        for spec in MANAGED_SPECS:
            event = str(spec["event"])
            expected_command = f"bash {wrapper} {spec['script']}"
            assert _count_entries(data, event, expected_command) == 1, (
                f"Duplicate entry detected for {event}/{spec['script']} with standard wrapper"
            )


class TestUpsertIdempotencyArbitraryWrapper:
    """Wrapper at an arbitrary path NOT containing run-hook-codex.sh — the bug case."""

    def test_double_upsert_no_duplicates(self, tmp_path: Path) -> None:
        hooks_file = tmp_path / "hooks.json"
        wrapper = str(tmp_path / "wrapper.sh")
        args = _make_args(str(hooks_file), wrapper)

        cmd_upsert_vibeguard(args)
        cmd_upsert_vibeguard(args)

        data = json.loads(hooks_file.read_text())
        for spec in MANAGED_SPECS:
            event = str(spec["event"])
            expected_command = f"bash {wrapper} {spec['script']}"
            assert _count_entries(data, event, expected_command) == 1, (
                f"Duplicate entry detected for {event}/{spec['script']} with arbitrary wrapper"
            )

    def test_triple_upsert_no_duplicates(self, tmp_path: Path) -> None:
        hooks_file = tmp_path / "hooks.json"
        wrapper = str(tmp_path / "wrapper.sh")
        args = _make_args(str(hooks_file), wrapper)

        cmd_upsert_vibeguard(args)
        cmd_upsert_vibeguard(args)
        cmd_upsert_vibeguard(args)

        data = json.loads(hooks_file.read_text())
        for spec in MANAGED_SPECS:
            event = str(spec["event"])
            expected_command = f"bash {wrapper} {spec['script']}"
            assert _count_entries(data, event, expected_command) == 1, (
                f"Entry multiplied beyond 1 after triple upsert for {event}/{spec['script']}"
            )

    def test_second_upsert_returns_skip(self, tmp_path: Path) -> None:
        """Second upsert with no changes should print SKIP (no-op)."""
        hooks_file = tmp_path / "hooks.json"
        wrapper = str(tmp_path / "wrapper.sh")
        args = _make_args(str(hooks_file), wrapper)

        cmd_upsert_vibeguard(args)
        content_after_first = hooks_file.read_text()

        cmd_upsert_vibeguard(args)
        content_after_second = hooks_file.read_text()

        assert content_after_first == content_after_second, (
            "hooks.json was modified by a no-op second upsert"
        )

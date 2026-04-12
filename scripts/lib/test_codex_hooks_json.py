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
    _build_entry,
    _ensure_hooks_root,
    _is_vibeguard_command,
    cmd_check_vibeguard,
    cmd_remove_vibeguard,
    cmd_upsert_vibeguard,
)


def _make_args(hooks_file: str, wrapper: str = "") -> argparse.Namespace:
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


class TestWrapperPathChange:
    """Upsert with a new wrapper path must prune stale entries from the old path."""

    def test_wrapper_change_removes_old_entries(self, tmp_path: Path) -> None:
        hooks_file = tmp_path / "hooks.json"
        old_wrapper = str(tmp_path / "old-wrapper.sh")
        new_wrapper = str(tmp_path / "new-wrapper.sh")

        cmd_upsert_vibeguard(_make_args(str(hooks_file), old_wrapper))
        cmd_upsert_vibeguard(_make_args(str(hooks_file), new_wrapper))

        data = json.loads(hooks_file.read_text())
        for spec in MANAGED_SPECS:
            event = str(spec["event"])
            old_command = f"bash {old_wrapper} {spec['script']}"
            new_command = f"bash {new_wrapper} {spec['script']}"
            assert _count_entries(data, event, old_command) == 0, (
                f"Stale entry for old wrapper still present after wrapper change: {event}/{spec['script']}"
            )
            assert _count_entries(data, event, new_command) == 1, (
                f"New wrapper entry missing after wrapper change: {event}/{spec['script']}"
            )

    def test_wrapper_change_from_standard_to_arbitrary(self, tmp_path: Path) -> None:
        hooks_file = tmp_path / "hooks.json"
        standard_wrapper = str(tmp_path / "run-hook-codex.sh")
        arbitrary_wrapper = str(tmp_path / "my-custom-wrapper.sh")

        cmd_upsert_vibeguard(_make_args(str(hooks_file), standard_wrapper))
        cmd_upsert_vibeguard(_make_args(str(hooks_file), arbitrary_wrapper))

        data = json.loads(hooks_file.read_text())
        for spec in MANAGED_SPECS:
            event = str(spec["event"])
            old_command = f"bash {standard_wrapper} {spec['script']}"
            assert _count_entries(data, event, old_command) == 0, (
                f"Standard wrapper entry survived switch to arbitrary wrapper: {event}/{spec['script']}"
            )


class TestRemoveArbitraryWrapper:
    """remove-vibeguard must uninstall arbitrary-wrapper entries."""

    def test_remove_clears_arbitrary_wrapper_entries(self, tmp_path: Path) -> None:
        hooks_file = tmp_path / "hooks.json"
        wrapper = str(tmp_path / "arbitrary-wrapper.sh")

        cmd_upsert_vibeguard(_make_args(str(hooks_file), wrapper))
        result = cmd_remove_vibeguard(_make_args(str(hooks_file)))

        assert result == 0
        import json as _json
        data = _json.loads(hooks_file.read_text()) if hooks_file.exists() else {}
        for spec in MANAGED_SPECS:
            event = str(spec["event"])
            command = f"bash {wrapper} {spec['script']}"
            assert _count_entries(data, event, command) == 0, (
                f"Arbitrary wrapper entry not removed by remove-vibeguard: {event}/{spec['script']}"
            )

    def test_remove_after_standard_wrapper_install(self, tmp_path: Path) -> None:
        hooks_file = tmp_path / "hooks.json"
        wrapper = str(tmp_path / "run-hook-codex.sh")

        cmd_upsert_vibeguard(_make_args(str(hooks_file), wrapper))
        result = cmd_remove_vibeguard(_make_args(str(hooks_file)))

        assert result == 0
        data = json.loads(hooks_file.read_text()) if hooks_file.exists() else {}
        for spec in MANAGED_SPECS:
            event = str(spec["event"])
            command = f"bash {wrapper} {spec['script']}"
            assert _count_entries(data, event, command) == 0, (
                f"Standard wrapper entry not removed by remove-vibeguard: {event}/{spec['script']}"
            )


class TestIsVibeGuardCommandThirdPartyIsolation:
    """_is_vibeguard_command() must not claim third-party hooks that happen to end with
    a generic legacy marker name (Issue 1 from round-2 review)."""

    def test_third_party_hook_with_legacy_pre_bash_guard_name(self) -> None:
        # A command from another tool that ends with a legacy ambiguous script name.
        assert not _is_vibeguard_command("bash /other-tool/wrapper.sh pre-bash-guard.sh"), (
            "Third-party hook ending with 'pre-bash-guard.sh' must not be classified as VibeGuard"
        )

    def test_third_party_hook_with_legacy_stop_guard_name(self) -> None:
        assert not _is_vibeguard_command("bash /other-tool/wrapper.sh stop-guard.sh"), (
            "Third-party hook ending with 'stop-guard.sh' must not be classified as VibeGuard"
        )

    def test_third_party_shell_flag_with_legacy_name(self) -> None:
        # "bash -lc stop-guard.sh" — 3 tokens, starts with bash, ends with legacy name.
        assert not _is_vibeguard_command("bash -lc stop-guard.sh"), (
            "'bash -lc stop-guard.sh' must not be classified as VibeGuard"
        )

    def test_vibeguard_prefixed_script_is_claimed(self) -> None:
        # A valid VibeGuard command with a vibeguard- prefixed script must still match.
        assert _is_vibeguard_command(
            "bash /some/arbitrary/wrapper.sh vibeguard-pre-bash-guard.sh"
        ), "Arbitrary wrapper with current vibeguard-prefixed script must be classified as VibeGuard"


class TestCheckVibeGuard:
    """check-vibeguard must fail when stale duplicate entries exist."""

    def test_check_passes_clean_install(self, tmp_path: Path) -> None:
        hooks_file = tmp_path / "hooks.json"
        wrapper = str(tmp_path / "wrapper.sh")

        cmd_upsert_vibeguard(_make_args(str(hooks_file), wrapper))
        result = cmd_check_vibeguard(_make_args(str(hooks_file), wrapper))

        assert result == 0, "check-vibeguard should succeed after clean upsert"

    def test_check_fails_when_stale_entries_exist(self, tmp_path: Path) -> None:
        hooks_file = tmp_path / "hooks.json"
        old_wrapper = str(tmp_path / "old-wrapper.sh")
        new_wrapper = str(tmp_path / "new-wrapper.sh")

        # Manually install old wrapper entries, then install new wrapper WITHOUT pruning,
        # to simulate stale + new entries coexisting.
        cmd_upsert_vibeguard(_make_args(str(hooks_file), old_wrapper))

        # Directly append new-wrapper entries without pruning old ones (simulate the bug).
        data = json.loads(hooks_file.read_text())
        from codex_hooks_json import _build_entry, _ensure_hooks_root, MANAGED_SPECS as _SPECS
        hooks = _ensure_hooks_root(data)
        for spec in _SPECS:
            event = str(spec["event"])
            entries = hooks.setdefault(event, [])
            entries.append(_build_entry(new_wrapper, spec))
        hooks_file.write_text(json.dumps(data, indent=2) + "\n")

        result = cmd_check_vibeguard(_make_args(str(hooks_file), new_wrapper))

        assert result == 1, "check-vibeguard should fail when stale old-wrapper entries exist alongside new ones"

    def test_check_fails_missing_entries(self, tmp_path: Path) -> None:
        hooks_file = tmp_path / "hooks.json"
        wrapper = str(tmp_path / "wrapper.sh")

        result = cmd_check_vibeguard(_make_args(str(hooks_file), wrapper))

        assert result == 1, "check-vibeguard should fail when no entries are installed"

    def test_check_fails_same_wrapper_duplicates(self, tmp_path: Path) -> None:
        """check-vibeguard must return 1 when same-wrapper entries are duplicated (Issue 2).

        Duplicated entries cause hooks to fire multiple times in production.
        cmd_check_vibeguard() must catch this even when stale-check passes (same wrapper).
        """
        hooks_file = tmp_path / "hooks.json"
        wrapper = str(tmp_path / "wrapper.sh")

        # First install via the normal path.
        cmd_upsert_vibeguard(_make_args(str(hooks_file), wrapper))

        # Manually inject a second copy of every entry (simulates corrupted state).
        data = json.loads(hooks_file.read_text())
        hooks = _ensure_hooks_root(data)
        for spec in MANAGED_SPECS:
            event = str(spec["event"])
            entries = hooks.setdefault(event, [])
            entries.append(_build_entry(wrapper, spec))
        hooks_file.write_text(json.dumps(data, indent=2) + "\n")

        result = cmd_check_vibeguard(_make_args(str(hooks_file), wrapper))

        assert result == 1, (
            "check-vibeguard must fail when same-wrapper entries are duplicated — "
            "duplicate hooks fire multiple times per event"
        )

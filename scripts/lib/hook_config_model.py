#!/usr/bin/env python3
"""Typed hook config identity shared by Claude and Codex setup helpers."""

from __future__ import annotations

import shlex
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


@dataclass(frozen=True)
class HookIdentity:
    platform: str
    event: str
    matcher: str | None
    command: str
    script: str | None
    wrapper: str | None
    timeout: int | None
    managed_id: str | None

    @property
    def is_managed(self) -> bool:
        return self.managed_id is not None


def _basename(token: str) -> str:
    return Path(token).name


def _script_id(script: str) -> str:
    return script[:-3] if script.endswith(".sh") else script


def _shell_invokes_wrapper(parts: list[str], index: int) -> bool:
    if index < 2:
        return False
    shell = _basename(parts[index - 2])
    wrapper = parts[index - 1]
    return shell in {"bash", "sh", "zsh"} and not wrapper.startswith("-")


def _looks_like_direct_script(parts: list[str], index: int) -> bool:
    token = parts[index]
    if "/" in token or token.startswith(("./", "../", "~/", "$HOME/", "${HOME}/")):
        return True
    if index > 0 and _basename(parts[index - 1]) in {"bash", "sh", "zsh"}:
        return True
    return index == 0 and token.endswith(".sh")


def hook_command_identity(
    *,
    platform: str,
    event: str,
    matcher: str | None,
    command: str,
    timeout: int | None,
    managed_scripts: Iterable[str],
    legacy_scripts: Iterable[str] = (),
    wrapper_names: Iterable[str] = (),
    standalone_legacy_scripts: Iterable[str] = (),
) -> HookIdentity:
    managed_set = frozenset(managed_scripts)
    legacy_set = frozenset(legacy_scripts)
    all_known_scripts = managed_set | legacy_set
    wrapper_set = frozenset(wrapper_names)
    standalone_legacy_set = frozenset(standalone_legacy_scripts)

    script: str | None = None
    wrapper: str | None = None
    try:
        parts = shlex.split(command)
    except ValueError:
        parts = []

    for index, token in enumerate(parts):
        token_base = _basename(token)
        if token_base not in wrapper_set:
            continue
        wrapper = token_base
        if index + 1 >= len(parts):
            continue
        next_script = _basename(parts[index + 1])
        if next_script in all_known_scripts:
            script = next_script
            break

    if script is None:
        for index, token in enumerate(parts):
            token_base = _basename(token)
            if token_base in managed_set and (
                _looks_like_direct_script(parts, index) or _shell_invokes_wrapper(parts, index)
            ):
                script = token_base
                break
            if token_base in standalone_legacy_set and _looks_like_direct_script(parts, index):
                script = token_base
                break

    managed_id = _script_id(script) if script in all_known_scripts else None
    return HookIdentity(
        platform=platform,
        event=event,
        matcher=matcher,
        command=command,
        script=script,
        wrapper=wrapper,
        timeout=timeout,
        managed_id=managed_id,
    )


def normalize_hook_entry(
    *,
    platform: str,
    event: str,
    entry: Any,
    managed_scripts: Iterable[str],
    legacy_scripts: Iterable[str] = (),
    wrapper_names: Iterable[str] = (),
    standalone_legacy_scripts: Iterable[str] = (),
) -> list[HookIdentity]:
    if not isinstance(entry, dict):
        return []
    matcher_value = entry.get("matcher")
    matcher = matcher_value if isinstance(matcher_value, str) and matcher_value else None
    hook_entries = entry.get("hooks")
    if not isinstance(hook_entries, list):
        return []

    identities: list[HookIdentity] = []
    for hook in hook_entries:
        if not isinstance(hook, dict):
            continue
        command = hook.get("command")
        if not isinstance(command, str) or not command:
            continue
        timeout_value = hook.get("timeout")
        timeout = timeout_value if isinstance(timeout_value, int) else None
        identities.append(
            hook_command_identity(
                platform=platform,
                event=event,
                matcher=matcher,
                command=command,
                timeout=timeout,
                managed_scripts=managed_scripts,
                legacy_scripts=legacy_scripts,
                wrapper_names=wrapper_names,
                standalone_legacy_scripts=standalone_legacy_scripts,
            )
        )
    return identities

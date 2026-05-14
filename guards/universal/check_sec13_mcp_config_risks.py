#!/usr/bin/env python3
"""SEC-13 high-context MCP/settings risk-field scanner."""

from __future__ import annotations

import json
import re
import shlex
import sys
from pathlib import Path
from typing import Any


SCRIPT_EXTENSIONS = {".sh", ".py", ".js", ".ts", ".mjs", ".cjs"}
SKIP_DIRS = {".git", "node_modules", "target", "dist", "build", "__pycache__", ".venv"}


def candidate_files(root: Path) -> list[Path]:
    candidates: list[Path] = []
    fixed = [root / ".mcp.json", root / ".claude.json"]
    candidates.extend(path for path in fixed if path.is_file())

    claude_dir = root / ".claude"
    if claude_dir.is_dir():
        candidates.extend(path for path in sorted(claude_dir.glob("settings*.json")) if path.is_file())

    return candidates


def json_path(parent: str, key: str | int) -> str:
    if isinstance(key, int):
        return f"{parent}[{key}]"
    if parent == "$":
        return f"$.{key}"
    return f"{parent}.{key}"


def walk_json(value: Any, path: str = "$"):
    if isinstance(value, dict):
        for key, child in value.items():
            yield json_path(path, key), key, child
            yield from walk_json(child, json_path(path, key))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield json_path(path, index), index, child
            yield from walk_json(child, json_path(path, index))


def is_non_empty_enabled_servers(value: Any) -> bool:
    if isinstance(value, list):
        return len(value) > 0
    if isinstance(value, dict):
        return len(value) > 0
    if isinstance(value, str):
        return value.strip() != ""
    return bool(value)


def is_mcp_only_matcher(matcher: Any) -> bool:
    if not isinstance(matcher, str) or matcher.strip() == "":
        return False
    parts = [part.strip() for part in re.split(r"[|,]", matcher) if part.strip()]
    return bool(parts) and all(part.startswith("mcp__") for part in parts)


def command_candidates(command: str, settings_file: Path, root: Path) -> list[Path]:
    try:
        parts = shlex.split(command)
    except ValueError:
        parts = command.split()

    paths: list[Path] = []
    for token in parts:
        if token.startswith("-"):
            continue
        token_path = Path(token)
        if token_path.suffix not in SCRIPT_EXTENSIONS:
            continue
        if token_path.is_absolute():
            paths.append(token_path)
        else:
            paths.append((settings_file.parent / token_path).resolve())
            paths.append((root / token_path).resolve())
    return paths


def command_or_script_rewrites_output(command: str, settings_file: Path, root: Path) -> bool:
    if "updatedToolOutput" in command:
        return True

    for script_path in command_candidates(command, settings_file, root):
        try:
            if script_path.is_file() and "updatedToolOutput" in script_path.read_text(
                encoding="utf-8", errors="ignore"
            ):
                return True
        except OSError:
            continue
    return False


def scan_post_tool_hooks(settings_file: Path, root: Path, data: Any) -> list[str]:
    if not isinstance(data, dict):
        return []
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        return []
    post_tool_use = hooks.get("PostToolUse")
    if not isinstance(post_tool_use, list):
        return []

    findings: list[str] = []
    for index, entry in enumerate(post_tool_use):
        if not isinstance(entry, dict):
            continue
        matcher = entry.get("matcher", "")
        if is_mcp_only_matcher(matcher):
            continue
        hook_entries = entry.get("hooks", [])
        if not isinstance(hook_entries, list):
            continue
        for hook_index, hook_entry in enumerate(hook_entries):
            if not isinstance(hook_entry, dict):
                continue
            command = hook_entry.get("command")
            if not isinstance(command, str):
                continue
            if command_or_script_rewrites_output(command, settings_file, root):
                findings.append(
                    f"{settings_file}:$.hooks.PostToolUse[{index}].hooks[{hook_index}].command "
                    "PostToolUse rewrites updatedToolOutput for non-MCP matcher"
                )
    return findings


def scan_json_file(path: Path, root: Path) -> list[str]:
    text = path.read_text(encoding="utf-8", errors="ignore")
    findings: list[str] = []

    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        if re.search(r'"?enableAllProjectMcpServers"?\s*:\s*true\b', text):
            findings.append(f"{path}: enableAllProjectMcpServers true")
        if re.search(r'"?alwaysLoad"?\s*:\s*true\b', text):
            findings.append(f"{path}: alwaysLoad true")
        if re.search(r'"?enabledMcpjsonServers"?\s*:\s*(\[[^\]\s][^\]]*\]|\{[^}\s][^}]*\}|\"[^\"]+\")', text):
            findings.append(f"{path}: enabledMcpjsonServers non-empty")
        return findings

    for path_expr, key, value in walk_json(data):
        if key == "enableAllProjectMcpServers" and value is True:
            findings.append(f"{path}:{path_expr} enableAllProjectMcpServers true")
        elif key == "enabledMcpjsonServers" and is_non_empty_enabled_servers(value):
            findings.append(f"{path}:{path_expr} enabledMcpjsonServers non-empty")
        elif key == "alwaysLoad" and value is True:
            findings.append(f"{path}:{path_expr} alwaysLoad true")

    if path.name.startswith("settings") and path.parent.name == ".claude":
        findings.extend(scan_post_tool_hooks(path, root, data))

    return findings


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    if not root.exists():
        print(f"[SEC-13] target does not exist: {root}", file=sys.stderr)
        return 2

    findings: list[str] = []
    for file_path in candidate_files(root):
        if any(part in SKIP_DIRS for part in file_path.relative_to(root).parts):
            continue
        findings.extend(scan_json_file(file_path, root))

    if findings:
        print("[SEC-13] high-risk MCP/settings fields detected")
        for finding in findings:
            print(f"- {finding}")
        print("Required: human diff review and project SECURITY.md/ADR decision before trusting this config.")
        return 1

    print("[SEC-13] OK: no high-risk MCP/settings fields detected")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

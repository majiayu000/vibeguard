#!/usr/bin/env python3
"""Helpers for structured updates to ~/.codex/config.toml."""

from __future__ import annotations

import argparse
import tempfile
from pathlib import Path


def _write_atomic(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", delete=False, encoding="utf-8", dir=path.parent) as tmp:
        tmp.write(content)
        tmp_path = Path(tmp.name)
    tmp_path.replace(path)


def _ensure_codex_hooks_enabled(text: str) -> tuple[str, bool]:
    lines = text.splitlines()
    if not lines:
        return "[features]\ncodex_hooks = true\n", True

    changed = False
    features_idx: int | None = None
    insert_idx: int | None = None
    in_features = False

    for idx, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            if stripped == "[features]":
                features_idx = idx
                in_features = True
                insert_idx = idx + 1
                continue
            if in_features:
                insert_idx = idx
                in_features = False
        if in_features:
            if stripped.startswith("codex_hooks"):
                if stripped != "codex_hooks = true":
                    lines[idx] = "codex_hooks = true"
                    changed = True
                return "\n".join(lines).rstrip() + "\n", changed

    if features_idx is not None:
        assert insert_idx is not None
        lines.insert(insert_idx, "codex_hooks = true")
        changed = True
        return "\n".join(lines).rstrip() + "\n", changed

    content = "\n".join(lines).rstrip()
    suffix = "\n\n" if content else ""
    return content + suffix + "[features]\ncodex_hooks = true\n", True


def _remove_legacy_vibeguard_mcp(text: str) -> tuple[str, bool]:
    lines = text.splitlines()
    if not lines:
        return "", False

    kept: list[str] = []
    in_legacy = False
    changed = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            if stripped == "[mcp_servers.vibeguard]":
                in_legacy = True
                changed = True
                continue
            in_legacy = False
        if in_legacy:
            changed = True
            continue
        kept.append(line)
    new_text = "\n".join(kept).strip()
    return ((new_text + "\n") if new_text else ""), changed


def cmd_enable_codex_hooks(args: argparse.Namespace) -> int:
    path = Path(args.config_file)
    old = path.read_text(encoding="utf-8") if path.exists() else ""
    new, changed = _ensure_codex_hooks_enabled(old)
    if changed or not path.exists():
        _write_atomic(path, new)
        print("CHANGED")
    else:
        print("SKIP")
    return 0


def cmd_remove_legacy_vibeguard_mcp(args: argparse.Namespace) -> int:
    path = Path(args.config_file)
    if not path.exists():
        print("SKIP")
        return 0
    old = path.read_text(encoding="utf-8")
    new, changed = _remove_legacy_vibeguard_mcp(old)
    if not changed:
        print("SKIP")
        return 0
    if new:
        _write_atomic(path, new)
    else:
        path.unlink(missing_ok=True)
    print("CHANGED")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Structured Codex config.toml helper")
    sub = parser.add_subparsers(dest="command", required=True)

    enable = sub.add_parser("enable-codex-hooks", help="Ensure [features].codex_hooks = true")
    enable.add_argument("--config-file", required=True)

    remove = sub.add_parser("remove-legacy-vibeguard-mcp", help="Remove [mcp_servers.vibeguard] block")
    remove.add_argument("--config-file", required=True)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if args.command == "enable-codex-hooks":
        return cmd_enable_codex_hooks(args)
    if args.command == "remove-legacy-vibeguard-mcp":
        return cmd_remove_legacy_vibeguard_mcp(args)
    parser.error("unknown command")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())

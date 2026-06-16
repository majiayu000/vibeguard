#!/usr/bin/env python3
"""Helpers for structured updates to ~/.codex/config.toml."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

from file_ops import write_text_atomic

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - Python < 3.11
    try:
        import tomli as tomllib
    except ModuleNotFoundError:  # pragma: no cover - pip vendor fallback
        from pip._vendor import tomli as tomllib


def _table_name(line: str) -> str | None:
    match = re.match(r"^\[\s*([^\]]+?)\s*\]\s*(?:#.*)?$", line.strip())
    return match.group(1).strip() if match else None


CODEX_HOOKS_FEATURE = "hooks"


def _ensure_hooks_enabled(text: str) -> tuple[str, bool]:
    lines = text.splitlines()
    if not lines:
        return f"[features]\n{CODEX_HOOKS_FEATURE} = true\n", True

    changed = False
    features_idx: int | None = None
    insert_idx: int | None = None
    in_features = False
    hooks_idx: int | None = None

    for idx, line in enumerate(lines):
        stripped = line.strip()
        table_name = _table_name(line)
        if table_name is not None:
            if table_name == "features":
                features_idx = idx
                in_features = True
                insert_idx = idx + 1
                continue
            if in_features:
                insert_idx = idx
                in_features = False
        if in_features:
            key = stripped.split("=", 1)[0].strip()
            if key == CODEX_HOOKS_FEATURE:
                hooks_idx = idx
                if stripped != f"{CODEX_HOOKS_FEATURE} = true":
                    lines[idx] = f"{CODEX_HOOKS_FEATURE} = true"
                    changed = True

    if features_idx is not None:
        assert insert_idx is not None
        if hooks_idx is None:
            lines.insert(insert_idx, "hooks = true")
            changed = True
        return "\n".join(lines).rstrip() + "\n", changed

    content = "\n".join(lines).rstrip()
    suffix = "\n\n" if content else ""
    return content + suffix + f"[features]\n{CODEX_HOOKS_FEATURE} = true\n", True


def _check_hooks_enabled(text: str) -> tuple[str, int]:
    try:
        data = tomllib.loads(text)
    except tomllib.TOMLDecodeError:
        return "INVALID", 1

    features = data.get("features")
    if isinstance(features, dict) and features.get(CODEX_HOOKS_FEATURE) is True:
        return "OK", 0
    return "MISSING", 1


def cmd_enable_hooks(args: argparse.Namespace) -> int:
    path = Path(args.config_file)
    old = path.read_text(encoding="utf-8") if path.exists() else ""
    new, changed = _ensure_hooks_enabled(old)
    if changed or not path.exists():
        write_text_atomic(path, new)
        print("CHANGED")
    else:
        print("SKIP")
    return 0


def cmd_check_hooks(args: argparse.Namespace) -> int:
    path = Path(args.config_file)
    if not path.exists():
        print("MISSING")
        return 1

    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        print("INVALID")
        return 1

    status, code = _check_hooks_enabled(text)
    print(status)
    return code


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Structured Codex config.toml helper")
    sub = parser.add_subparsers(dest="command", required=True)

    enable = sub.add_parser("enable-hooks", help="Ensure [features].hooks = true")
    enable.add_argument("--config-file", required=True)

    check = sub.add_parser("check-hooks", help="Validate [features].hooks = true")
    check.add_argument("--config-file", required=True)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if args.command == "enable-hooks":
        return cmd_enable_hooks(args)
    if args.command == "check-hooks":
        return cmd_check_hooks(args)
    parser.error("unknown command")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""VibeGuard Codex MCP config helper.

This helper intentionally uses a strategy pattern so Codex support is decoupled
from Claude Code setup logic:

- CodexCliMcpStrategy: use `codex mcp` commands (preferred)
- TomlFileMcpStrategy: direct ~/.codex/config.toml fallback
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from abc import ABC, abstractmethod
from dataclasses import dataclass
from pathlib import Path
from typing import Any

try:
    import tomllib  # py311+
except ModuleNotFoundError:  # pragma: no cover
    tomllib = None

SERVER_NAME = "vibeguard"


@dataclass(frozen=True)
class DesiredServer:
    command: str
    args: list[str]


def desired_server(repo_dir: str) -> DesiredServer:
    return DesiredServer(
        command="node",
        args=[str(Path(repo_dir) / "mcp-server" / "dist" / "index.js")],
    )


class McpStrategy(ABC):
    name: str

    @abstractmethod
    def check(self, desired: DesiredServer) -> bool:
        raise NotImplementedError

    @abstractmethod
    def upsert(self, desired: DesiredServer) -> bool:
        """Returns True when changed, False when already up-to-date."""
        raise NotImplementedError

    @abstractmethod
    def remove(self) -> bool:
        """Returns True when changed, False when no-op."""
        raise NotImplementedError


class CodexCliMcpStrategy(McpStrategy):
    name = "codex-cli"

    @staticmethod
    def _run(args: list[str]) -> subprocess.CompletedProcess[str]:
        return subprocess.run(args, text=True, capture_output=True)

    @staticmethod
    def _extract_json(stdout: str) -> dict[str, Any] | None:
        # Some Codex versions may print warnings before JSON.
        start = stdout.find("{")
        end = stdout.rfind("}")
        if start == -1 or end == -1 or end <= start:
            return None
        try:
            return json.loads(stdout[start : end + 1])
        except json.JSONDecodeError:
            return None

    def _current(self) -> dict[str, Any] | None:
        proc = self._run(["codex", "mcp", "get", SERVER_NAME, "--json"])
        if proc.returncode != 0:
            return None
        return self._extract_json(proc.stdout)

    def _matches(self, cfg: dict[str, Any] | None, desired: DesiredServer) -> bool:
        if not isinstance(cfg, dict):
            return False
        transport = cfg.get("transport")
        if not isinstance(transport, dict):
            return False
        return transport.get("type") == "stdio" and transport.get("command") == desired.command and transport.get("args") == desired.args

    def check(self, desired: DesiredServer) -> bool:
        return self._matches(self._current(), desired)

    def upsert(self, desired: DesiredServer) -> bool:
        current = self._current()
        if self._matches(current, desired):
            return False

        if current is not None:
            rm = self._run(["codex", "mcp", "remove", SERVER_NAME])
            if rm.returncode != 0:
                raise RuntimeError(f"failed to remove existing Codex MCP config: {rm.stderr.strip()}")

        add = self._run([
            "codex",
            "mcp",
            "add",
            SERVER_NAME,
            "--",
            desired.command,
            *desired.args,
        ])
        if add.returncode != 0:
            raise RuntimeError(f"failed to add Codex MCP config: {add.stderr.strip()}")

        return True

    def remove(self) -> bool:
        current = self._current()
        if current is None:
            return False
        rm = self._run(["codex", "mcp", "remove", SERVER_NAME])
        if rm.returncode != 0:
            raise RuntimeError(f"failed to remove Codex MCP config: {rm.stderr.strip()}")
        return True


class TomlFileMcpStrategy(McpStrategy):
    name = "toml-file"

    def __init__(self) -> None:
        self.config_path = Path.home() / ".codex" / "config.toml"

    @staticmethod
    def _remove_server_block(text: str) -> str:
        # Remove [mcp_servers.vibeguard] ... until next [section] or EOF.
        pattern = re.compile(
            rf"(?ms)^\[mcp_servers\.{re.escape(SERVER_NAME)}\]\n(?:.*?\n)*(?=^\[|\Z)"
        )
        return pattern.sub("", text)

    @staticmethod
    def _render_server_block(desired: DesiredServer) -> str:
        args = ", ".join(json.dumps(arg) for arg in desired.args)
        return (
            f"[mcp_servers.{SERVER_NAME}]\n"
            f"command = {json.dumps(desired.command)}\n"
            f"args = [{args}]\n"
        )

    def _load_toml(self) -> dict[str, Any]:
        if not self.config_path.exists():
            return {}
        if tomllib is None:
            return {}
        try:
            with self.config_path.open("rb") as f:
                data = tomllib.load(f)
            return data if isinstance(data, dict) else {}
        except Exception:
            return {}

    def _current_from_toml(self) -> dict[str, Any] | None:
        data = self._load_toml()
        servers = data.get("mcp_servers", {})
        if not isinstance(servers, dict):
            return None
        cfg = servers.get(SERVER_NAME)
        if not isinstance(cfg, dict):
            return None
        command = cfg.get("command")
        args = cfg.get("args")
        if not isinstance(command, str) or not isinstance(args, list):
            return None
        if not all(isinstance(x, str) for x in args):
            return None
        return {"command": command, "args": args}

    def _current_from_text(self) -> dict[str, Any] | None:
        if not self.config_path.exists():
            return None
        text = self.config_path.read_text(encoding="utf-8")
        block_match = re.search(
            rf"(?ms)^\[mcp_servers\.{re.escape(SERVER_NAME)}\]\n(.*?)(?=^\[|\Z)",
            text,
        )
        if not block_match:
            return None
        block = block_match.group(1)
        command_match = re.search(r"(?m)^command\s*=\s*(.+?)\s*$", block)
        args_match = re.search(r"(?m)^args\s*=\s*(.+?)\s*$", block)
        if not command_match or not args_match:
            return None
        try:
            command = json.loads(command_match.group(1))
            args = json.loads(args_match.group(1))
        except json.JSONDecodeError:
            return None
        if not isinstance(command, str) or not isinstance(args, list):
            return None
        if not all(isinstance(x, str) for x in args):
            return None
        return {"command": command, "args": args}

    def _current(self) -> dict[str, Any] | None:
        return self._current_from_toml() or self._current_from_text()

    def check(self, desired: DesiredServer) -> bool:
        current = self._current()
        if not isinstance(current, dict):
            return False
        return current.get("command") == desired.command and current.get("args") == desired.args

    def upsert(self, desired: DesiredServer) -> bool:
        old = self.config_path.read_text(encoding="utf-8") if self.config_path.exists() else ""
        cleaned = self._remove_server_block(old).rstrip()
        block = self._render_server_block(desired).rstrip()
        new = f"{cleaned}\n\n{block}\n" if cleaned else f"{block}\n"

        if new == old:
            return False

        self.config_path.parent.mkdir(parents=True, exist_ok=True)
        self.config_path.write_text(new, encoding="utf-8")
        return True

    def remove(self) -> bool:
        if not self.config_path.exists():
            return False

        old = self.config_path.read_text(encoding="utf-8")
        new = self._remove_server_block(old)
        new = re.sub(r"\n{3,}", "\n\n", new).strip()
        new = (new + "\n") if new else ""

        if new == old:
            return False

        if new:
            self.config_path.write_text(new, encoding="utf-8")
        else:
            self.config_path.unlink(missing_ok=True)
        return True


def choose_strategy() -> McpStrategy:
    if _codex_cli_supports_mcp():
        return CodexCliMcpStrategy()
    return TomlFileMcpStrategy()


def _codex_cli_supports_mcp() -> bool:
    if not shutil.which("codex"):
        return False
    try:
        probe = subprocess.run(
            ["codex", "mcp", "--help"],
            text=True,
            capture_output=True,
        )
    except OSError:
        return False
    if probe.returncode == 0:
        return True
    combined = f"{probe.stdout}\n{probe.stderr}".lower()
    unsupported_markers = (
        "unknown subcommand",
        "unknown command",
        "unrecognized subcommand",
        "unrecognized command",
        "no such command",
    )
    if any(marker in combined for marker in unsupported_markers):
        return False
    return False


def run_with_fallback(
    command: str,
    desired: DesiredServer,
    strategy: McpStrategy,
) -> tuple[bool, McpStrategy]:
    try:
        if command == "check":
            return strategy.check(desired), strategy
        if command == "upsert":
            return strategy.upsert(desired), strategy
        if command == "remove":
            return strategy.remove(), strategy
        raise ValueError(f"unsupported command: {command}")
    except RuntimeError as exc:
        if not isinstance(strategy, CodexCliMcpStrategy):
            raise
        fallback = TomlFileMcpStrategy()
        print(
            f"[vibeguard-codex-mcp] codex-cli failed, fallback to toml-file: {exc}",
            file=sys.stderr,
        )
        if command == "check":
            return fallback.check(desired), fallback
        if command == "upsert":
            return fallback.upsert(desired), fallback
        return fallback.remove(), fallback


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="VibeGuard Codex MCP helper")
    sub = p.add_subparsers(dest="command", required=True)

    for cmd in ("check", "upsert", "remove"):
        sp = sub.add_parser(cmd)
        sp.add_argument("--repo-dir", required=True)
    return p


def main() -> int:
    args = build_parser().parse_args()
    desired = desired_server(args.repo_dir)
    strategy = choose_strategy()

    if args.command == "check":
        ok, _used = run_with_fallback(args.command, desired, strategy)
        return 0 if ok else 1

    if args.command == "upsert":
        changed, used = run_with_fallback(args.command, desired, strategy)
        print("CHANGED" if changed else "SKIP")
        print(f"STRATEGY:{used.name}")
        return 0

    if args.command == "remove":
        changed, used = run_with_fallback(args.command, desired, strategy)
        print("CHANGED" if changed else "SKIP")
        print(f"STRATEGY:{used.name}")
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())

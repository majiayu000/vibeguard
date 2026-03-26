#!/usr/bin/env python3
"""VibeGuard wrapper for `codex app-server`.

This wrapper is optional and does not change Claude Code behavior. It is designed
for Codex app-server orchestrators (for example Symphony-like runtimes) that need
external guard rails.

Current guard coverage (best-effort):
- pre gate: `pre-bash-guard.sh` on command approval requests
- stop gate: `stop-guard.sh` and `learn-evaluator.sh` after turn completion
- post gate: `post-build-check.sh` for changed source files after turn completion
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import threading
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable


@dataclass
class SessionState:
    thread_cwd: dict[str, str] = field(default_factory=dict)


@dataclass
class HookResult:
    decision: str
    output: str
    updated_command: str | None = None


class HookRunner:
    def __init__(self, repo_dir: Path) -> None:
        self.repo_dir = repo_dir
        self.hooks_dir = repo_dir / "hooks"

    def run(self, hook_name: str, payload: dict[str, Any], cwd: str | None = None) -> HookResult:
        hook_path = self.hooks_dir / hook_name
        if not hook_path.exists():
            return HookResult(decision="pass", output="")

        proc = subprocess.run(
            ["bash", str(hook_path)],
            input=json.dumps(payload, ensure_ascii=False),
            text=True,
            capture_output=True,
            cwd=cwd,
        )
        output = (proc.stdout or "") + ("\n" + proc.stderr if proc.stderr else "")
        decision = self._extract_decision(output) or "pass"
        updated_command = self._extract_updated_command(output) if decision == "allow" else None
        return HookResult(decision=decision, output=output.strip(), updated_command=updated_command)

    @staticmethod
    def _extract_decision(output: str) -> str | None:
        match = re.search(r'"decision"\s*:\s*"([a-zA-Z_-]+)"', output)
        if match:
            return match.group(1)
        return None

    @staticmethod
    def _extract_updated_command(output: str) -> str | None:
        for line in output.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                data = json.loads(line)
                if isinstance(data, dict):
                    updated = data.get("updatedInput")
                    if isinstance(updated, dict):
                        cmd = updated.get("command")
                        return cmd if isinstance(cmd, str) else None
            except json.JSONDecodeError:
                continue
        return None


class GateStrategy(ABC):
    @abstractmethod
    def on_client_message(self, message: dict[str, Any], state: SessionState) -> None:
        raise NotImplementedError

    @abstractmethod
    def handle_server_request(
        self,
        message: dict[str, Any],
        state: SessionState,
        write_to_server: Callable[[dict[str, Any]], None],
    ) -> bool:
        """Return True when the original request is intercepted and should not be forwarded."""
        raise NotImplementedError

    @abstractmethod
    def on_server_notification(self, message: dict[str, Any], state: SessionState) -> None:
        raise NotImplementedError


class NoopGateStrategy(GateStrategy):
    def on_client_message(self, message: dict[str, Any], state: SessionState) -> None:
        del message, state

    def handle_server_request(
        self,
        message: dict[str, Any],
        state: SessionState,
        write_to_server: Callable[[dict[str, Any]], None],
    ) -> bool:
        del message, state, write_to_server
        return False

    def on_server_notification(self, message: dict[str, Any], state: SessionState) -> None:
        del message, state


class VibeGuardGateStrategy(GateStrategy):
    def __init__(self, repo_dir: Path) -> None:
        self.hooks = HookRunner(repo_dir)

    def on_client_message(self, message: dict[str, Any], state: SessionState) -> None:
        method = message.get("method")
        params = message.get("params") if isinstance(message.get("params"), dict) else {}
        if not isinstance(params, dict):
            return

        if method == "thread/start":
            thread_id = params.get("threadId")
            cwd = params.get("cwd")
            if isinstance(thread_id, str) and isinstance(cwd, str) and cwd:
                state.thread_cwd[thread_id] = cwd
        elif method == "turn/start":
            thread_id = params.get("threadId")
            cwd = params.get("cwd")
            if isinstance(thread_id, str) and isinstance(cwd, str) and cwd:
                state.thread_cwd[thread_id] = cwd

    def handle_server_request(
        self,
        message: dict[str, Any],
        state: SessionState,
        write_to_server: Callable[[dict[str, Any]], None],
    ) -> bool:
        del state
        method = message.get("method")
        if method != "item/commandExecution/requestApproval":
            return False

        msg_id = message.get("id")
        params = message.get("params")
        if not isinstance(params, dict) or msg_id is None:
            return False

        command = params.get("command")
        if not isinstance(command, str) or not command.strip():
            return False

        payload = {"tool_input": {"command": command}}
        result = self.hooks.run("pre-bash-guard.sh", payload)

        if result.decision == "block":
            write_to_server({"id": msg_id, "result": {"decision": "decline"}})
            print(
                f"[vibeguard-codex-wrapper] blocked command approval: {command}",
                file=sys.stderr,
            )
            return True

        if result.updated_command is not None:
            write_to_server(
                {"id": msg_id, "result": {"decision": "approve", "updatedInput": {"command": result.updated_command}}}
            )
            print(
                f"[vibeguard-codex-wrapper] corrected command: {command!r} → {result.updated_command!r}",
                file=sys.stderr,
            )
            return True

        return False

    def on_server_notification(self, message: dict[str, Any], state: SessionState) -> None:
        if message.get("method") != "turn/completed":
            return

        params = message.get("params")
        if not isinstance(params, dict):
            return

        thread_id = params.get("threadId")
        if not isinstance(thread_id, str):
            return

        cwd = state.thread_cwd.get(thread_id)
        if not cwd:
            return

        self._run_stop_gates(cwd)
        self._run_post_build_checks(cwd)

    def _run_stop_gates(self, cwd: str) -> None:
        # stop-guard / learn-evaluator do not require stdin payload.
        self.hooks.run("stop-guard.sh", payload={}, cwd=cwd)
        self.hooks.run("learn-evaluator.sh", payload={}, cwd=cwd)

    def _run_post_build_checks(self, cwd: str) -> None:
        files = self._changed_files(cwd)
        for rel in files:
            abs_path = str(Path(cwd) / rel)
            payload = {"tool_input": {"file_path": abs_path}}
            self.hooks.run("post-build-check.sh", payload=payload, cwd=cwd)

    @staticmethod
    def _changed_files(cwd: str) -> list[str]:
        def run_git(args: list[str]) -> list[str]:
            proc = subprocess.run(
                ["git", "-C", cwd, *args],
                text=True,
                capture_output=True,
            )
            if proc.returncode != 0:
                return []
            return [line.strip() for line in proc.stdout.splitlines() if line.strip()]

        changed = set(run_git(["diff", "--name-only", "HEAD"]))
        changed.update(run_git(["diff", "--name-only", "--cached"]))
        source_exts = {".rs", ".py", ".ts", ".tsx", ".js", ".jsx", ".go"}
        return [p for p in sorted(changed) if Path(p).suffix in source_exts]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="VibeGuard Codex app-server wrapper")
    parser.add_argument(
        "--repo-dir",
        default=str(Path(__file__).resolve().parents[2]),
        help="VibeGuard repository root",
    )
    parser.add_argument(
        "--strategy",
        choices=["vibeguard", "noop"],
        default="vibeguard",
        help="Gate strategy implementation",
    )
    parser.add_argument(
        "--codex-command",
        default="codex app-server",
        help="Command used to launch app-server",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_dir = Path(args.repo_dir).resolve()

    strategy: GateStrategy
    if args.strategy == "noop":
        strategy = NoopGateStrategy()
    else:
        strategy = VibeGuardGateStrategy(repo_dir)

    state = SessionState()

    child = subprocess.Popen(
        ["bash", "-lc", args.codex_command],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )

    if child.stdin is None or child.stdout is None or child.stderr is None:
        print("failed to start codex app-server process", file=sys.stderr)
        return 1

    write_lock = threading.Lock()

    def write_to_server(obj: dict[str, Any]) -> None:
        with write_lock:
            child.stdin.write(json.dumps(obj, ensure_ascii=False) + "\n")
            child.stdin.flush()

    def client_to_server() -> None:
        for line in sys.stdin:
            stripped = line.strip()
            if stripped:
                try:
                    message = json.loads(stripped)
                    if isinstance(message, dict):
                        strategy.on_client_message(message, state)
                except json.JSONDecodeError:
                    pass
            with write_lock:
                child.stdin.write(line)
                child.stdin.flush()
        with write_lock:
            try:
                child.stdin.close()
            except Exception:
                pass

    def server_to_client() -> None:
        for line in child.stdout:
            stripped = line.strip()
            intercepted = False
            if stripped:
                try:
                    message = json.loads(stripped)
                    if isinstance(message, dict):
                        if "id" in message and isinstance(message.get("method"), str):
                            intercepted = strategy.handle_server_request(message, state, write_to_server)
                        elif isinstance(message.get("method"), str):
                            strategy.on_server_notification(message, state)
                except json.JSONDecodeError:
                    pass

            if not intercepted:
                sys.stdout.write(line)
                sys.stdout.flush()

    def server_stderr() -> None:
        for line in child.stderr:
            sys.stderr.write(line)
            sys.stderr.flush()

    t_in = threading.Thread(target=client_to_server, daemon=True)
    t_out = threading.Thread(target=server_to_client, daemon=True)
    t_err = threading.Thread(target=server_stderr, daemon=True)

    t_in.start()
    t_out.start()
    t_err.start()

    t_in.join()
    t_out.join()
    t_err.join(timeout=0.1)

    return child.wait()


if __name__ == "__main__":
    raise SystemExit(main())

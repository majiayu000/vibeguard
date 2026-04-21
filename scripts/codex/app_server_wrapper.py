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
import hashlib
import json
import os
import re
import subprocess
import sys
import threading
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable


CODEX_APP_SERVER_CAPABILITIES: dict[str, bool] = {
    "pre_bash_guard": True,
    "command_rewrite": True,
    "post_turn_feedback": True,
    "pre_edit_guard": False,
    "pre_write_guard": False,
    "post_edit_guard": False,
    "post_write_guard": False,
    "analysis_paralysis_guard": False,
}


@dataclass
class ThreadState:
    cwd: str | None = None
    session_id: str | None = None
    turn_id: str | None = None


@dataclass
class SessionState:
    threads: dict[str, ThreadState] = field(default_factory=dict)

    def ensure_thread(self, thread_id: str) -> ThreadState:
        state = self.threads.get(thread_id)
        if state is None:
            state = ThreadState(session_id=_session_id_for_thread(thread_id))
            self.threads[thread_id] = state
        elif not state.session_id:
            state.session_id = _session_id_for_thread(thread_id)
        return state


@dataclass
class HookResult:
    decision: str
    output: str
    payloads: list[dict[str, Any]] = field(default_factory=list)
    updated_command: str | None = None


class HookRunner:
    def __init__(self, repo_dir: Path) -> None:
        self.repo_dir = repo_dir
        self.hooks_dir = repo_dir / "hooks"

    def run(
        self,
        hook_name: str,
        payload: dict[str, Any],
        cwd: str | None = None,
        env_overrides: dict[str, str] | None = None,
    ) -> HookResult:
        hook_path = self.hooks_dir / hook_name
        if not hook_path.exists():
            return HookResult(decision="pass", output="")

        env = os.environ.copy()
        if env_overrides:
            env.update(env_overrides)
        try:
            proc = subprocess.run(
                ["bash", str(hook_path)],
                input=json.dumps(payload, ensure_ascii=False),
                text=True,
                capture_output=True,
                cwd=cwd,
                env=env,
            )
        except OSError as exc:
            output = f"hook failed to launch: {exc}"
            return HookResult(decision="hook_error", output=output)
        output = (proc.stdout or "") + ("\n" + proc.stderr if proc.stderr else "")
        if proc.returncode != 0:
            return HookResult(decision="hook_error", output=output.strip() or f"hook failed with exit {proc.returncode}")
        payloads = self._extract_payloads(output)
        decision = self._extract_decision(output, payloads) or "pass"
        updated_command = self._extract_updated_command(payloads) if decision == "allow" else None
        return HookResult(
            decision=decision,
            output=output.strip(),
            payloads=payloads,
            updated_command=updated_command,
        )

    @staticmethod
    def _extract_payloads(output: str) -> list[dict[str, Any]]:
        payloads: list[dict[str, Any]] = []
        stripped = output.strip()
        if not stripped:
            return payloads

        candidates: list[str] = [stripped]
        candidates.extend(line.strip() for line in output.splitlines() if line.strip())
        seen: set[str] = set()
        for candidate in candidates:
            if candidate in seen:
                continue
            seen.add(candidate)
            try:
                data = json.loads(candidate)
            except json.JSONDecodeError:
                continue
            if isinstance(data, dict):
                payloads.append(data)
        return payloads

    @staticmethod
    def _extract_decision(output: str, payloads: list[dict[str, Any]]) -> str | None:
        for payload in payloads:
            decision = payload.get("decision")
            if isinstance(decision, str):
                return decision
        match = re.search(r'"decision"\s*:\s*"([a-zA-Z_-]+)"', output)
        if match:
            return match.group(1)
        return None

    @staticmethod
    def _extract_updated_command(payloads: list[dict[str, Any]]) -> str | None:
        for payload in payloads:
            updated = payload.get("updatedInput")
            if isinstance(updated, dict):
                cmd = updated.get("command")
                if isinstance(cmd, str):
                    return cmd
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
    def on_server_notification(self, message: dict[str, Any], state: SessionState) -> dict[str, Any]:
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

    def on_server_notification(self, message: dict[str, Any], state: SessionState) -> dict[str, Any]:
        del state
        return message


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
            if isinstance(thread_id, str):
                thread = state.ensure_thread(thread_id)
                if isinstance(cwd, str) and cwd:
                    thread.cwd = cwd
        elif method == "turn/start":
            thread_id = params.get("threadId")
            cwd = params.get("cwd")
            if isinstance(thread_id, str):
                thread = state.ensure_thread(thread_id)
                if isinstance(cwd, str) and cwd:
                    thread.cwd = cwd
                turn_id = params.get("turnId")
                if isinstance(turn_id, str) and turn_id:
                    thread.turn_id = turn_id

    def handle_server_request(
        self,
        message: dict[str, Any],
        state: SessionState,
        write_to_server: Callable[[dict[str, Any]], None],
    ) -> bool:
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

        thread_id = params.get("threadId")
        thread = state.ensure_thread(thread_id) if isinstance(thread_id, str) else None
        cwd = thread.cwd if thread is not None else None
        env = self._hook_env(thread_id if isinstance(thread_id, str) else None, thread)

        payload = {"tool_input": {"command": command}}
        result = self.hooks.run("pre-bash-guard.sh", payload, cwd=cwd, env_overrides=env)

        if result.decision == "block":
            write_to_server({"id": msg_id, "result": {"decision": "decline"}})
            print(
                f"[vibeguard-codex-wrapper] blocked command approval: {command}",
                file=sys.stderr,
            )
            return True

        if result.decision == "hook_error":
            write_to_server({"id": msg_id, "result": {"decision": "decline"}})
            detail = result.output or "hook failed"
            print(
                f"[vibeguard-codex-wrapper] hook failed closed for {command!r}: {detail}",
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

    def on_server_notification(self, message: dict[str, Any], state: SessionState) -> dict[str, Any]:
        if message.get("method") != "turn/completed":
            return message

        params = message.get("params")
        if not isinstance(params, dict):
            return message

        thread_id = params.get("threadId")
        if not isinstance(thread_id, str):
            return message

        thread = state.ensure_thread(thread_id)
        turn_id = params.get("turnId")
        if isinstance(turn_id, str) and turn_id:
            thread.turn_id = turn_id

        cwd = thread.cwd
        if not cwd:
            return message

        feedback = self._collect_turn_feedback(cwd, thread_id, thread)
        if not feedback:
            return message

        next_params = dict(params)
        next_params["vibeguard"] = feedback
        next_message = dict(message)
        next_message["params"] = next_params
        return next_message

    def _hook_env(self, thread_id: str | None, thread: ThreadState | None) -> dict[str, str]:
        env = {
            "VIBEGUARD_CLI": "codex",
            "VIBEGUARD_AGENT_TYPE": "codex",
        }
        if thread is not None and thread.session_id:
            env["VIBEGUARD_SESSION_ID"] = thread.session_id
        if thread_id:
            env["VIBEGUARD_THREAD_ID"] = thread_id
        if thread is not None and thread.turn_id:
            env["VIBEGUARD_TURN_ID"] = thread.turn_id
        return env

    def _collect_turn_feedback(self, cwd: str, thread_id: str, thread: ThreadState) -> dict[str, Any] | None:
        env = self._hook_env(thread_id, thread)
        messages = self._run_stop_gates(cwd, env)
        messages.extend(self._run_post_build_checks(cwd, env))
        if not messages:
            return None

        feedback: dict[str, Any] = {
            "client": "codex-app-server",
            "capabilities": CODEX_APP_SERVER_CAPABILITIES,
            "messages": messages,
        }
        if thread.session_id:
            feedback["sessionId"] = thread.session_id
        if thread_id:
            feedback["threadId"] = thread_id
        if thread.turn_id:
            feedback["turnId"] = thread.turn_id
        return feedback

    def _run_stop_gates(self, cwd: str, env: dict[str, str]) -> list[dict[str, str]]:
        messages: list[dict[str, str]] = []
        for hook_name in ("stop-guard.sh", "learn-evaluator.sh"):
            result = self.hooks.run(hook_name, payload={}, cwd=cwd, env_overrides=env)
            messages.extend(self._feedback_messages(hook_name, result))
        return messages

    def _run_post_build_checks(self, cwd: str, env: dict[str, str]) -> list[dict[str, str]]:
        messages: list[dict[str, str]] = []
        files = self._changed_files(cwd)
        for rel in files:
            abs_path = str(Path(cwd) / rel)
            payload = {"tool_input": {"file_path": abs_path}}
            result = self.hooks.run("post-build-check.sh", payload=payload, cwd=cwd, env_overrides=env)
            messages.extend(self._feedback_messages("post-build-check.sh", result))
        return messages

    @staticmethod
    def _feedback_messages(hook_name: str, result: HookResult) -> list[dict[str, str]]:
        messages: list[dict[str, str]] = []
        for payload in result.payloads:
            stop_reason = payload.get("stopReason")
            if isinstance(stop_reason, str) and stop_reason:
                messages.append({"hook": hook_name, "kind": "stopReason", "text": stop_reason})
            system_message = payload.get("systemMessage")
            if isinstance(system_message, str) and system_message:
                messages.append({"hook": hook_name, "kind": "systemMessage", "text": system_message})
            hook_output = payload.get("hookSpecificOutput")
            if isinstance(hook_output, dict):
                additional_context = hook_output.get("additionalContext")
                if isinstance(additional_context, str) and additional_context:
                    messages.append(
                        {
                            "hook": hook_name,
                            "kind": "additionalContext",
                            "text": additional_context,
                        }
                    )
        return messages

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


def _session_id_for_thread(thread_id: str) -> str:
    normalized = re.sub(r"[^A-Za-z0-9_.-]+", "-", thread_id).strip("-")
    if not normalized:
        normalized = "thread"
    digest = hashlib.sha256(thread_id.encode("utf-8")).hexdigest()[:12]
    return f"codex-thread-{normalized}-{digest}"


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
                            message = strategy.on_server_notification(message, state)
                            line = json.dumps(message, ensure_ascii=False) + "\n"
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

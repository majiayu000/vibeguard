#!/usr/bin/env python3
"""Test an actual Grok CLI with temporary homes and a local scripted model endpoint."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading


class FixtureHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        body = json.dumps({"object": "list", "data": [
            {"id": "fixture", "object": "model", "owned_by": "fixture"}
        ]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        state = self.server.fixture
        tools = request.get("tools", [])
        if tools:
            state["tool_results"] = [message["content"] for message in request.get("messages", [])
                                     if message.get("role") == "tool"]
        if tools and not state["sent"]:
            state["sent"] = True
            delta = {"role": "assistant", "tool_calls": [{
                "index": 0, "id": "fixture-call", "type": "function",
                "function": {"name": "run_terminal_command", "arguments": json.dumps({
                    "command": state["command"], "description": "Local VibeGuard integration fixture"
                })}
            }]}
            finish = "tool_calls"
        else:
            delta = {"role": "assistant", "content": "Fixture complete."}
            finish = "stop"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for content, reason in [(delta, None), ({}, finish)]:
            chunk = {"id": "fixture-completion", "object": "chat.completion.chunk", "created": 1,
                     "model": "fixture", "choices": [{"index": 0, "delta": content,
                                                       "finish_reason": reason}]}
            self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


def checked(args, *, env=None):
    result = subprocess.run([str(arg) for arg in args], env=env, capture_output=True,
                            text=True, timeout=60, check=False)
    if result.returncode:
        raise RuntimeError(f"{args}: exit {result.returncode}: {result.stderr}")
    return result.stdout


def smoke(runtime, grok):
    if os.name != "posix":
        raise RuntimeError("This native-host smoke test requires macOS, Linux or WSL")
    server = ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="vibeguard-grok-host-") as temp:
            home = Path(temp)
            grok_home = home / ".grok"
            grok_home.mkdir()
            (grok_home / "config.toml").write_text(f'''[model.fixture]
model = "fixture"
base_url = "http://127.0.0.1:{server.server_port}/v1"
api_key = "fixture-not-a-real-key"
context_window = 128000
[compat.claude]
hooks = true
[telemetry]
enabled = false
''')
            workspace = home / "workspace"
            workspace.mkdir()
            checked(["git", "init", "-q", workspace])
            canary = workspace / "must-survive"
            canary.write_text("keep this untracked file")
            env = dict(os.environ, HOME=str(home), GROK_HOME=str(grok_home),
                       XAI_API_KEY="fixture-not-a-real-key", GROK_COMPAT_CLAUDE_HOOKS="1")
            for host in ("grok", "claude"):
                checked([runtime, "install", host, "--home", home])
                inspection = json.loads(checked([grok, "--cwd", workspace, "inspect", "--json"], env=env))
                hooks = [hook for hook in inspection["hooks"]
                         if f"hook {host} --state-dir" in hook.get("target", "")]
                if {hook["event"] for hook in hooks} != {
                    "pre_tool_use", "post_tool_use", "post_tool_use_failure"
                }:
                    raise RuntimeError(f"Grok did not discover {host} registrations: {hooks}")
                if (grok_home / "rules/vibeguard.md").exists():
                    raise RuntimeError("Grok installation injected a default rule file")
                for command, outcome, exit_code, feedback in [
                    ("printf grok-smoke", "exited_zero", 0, "grok-smoke"),
                    ("exit 7", "exited_nonzero", 7, "exit: 7"),
                    ("git clean -fd", "denied", None, "Hook denied:"),
                ]:
                    server.fixture = {"command": command, "sent": False, "tool_results": []}
                    checked([grok, "--cwd", workspace, "-m", "fixture", "--no-subagents",
                             "--max-turns", "3", "--always-approve", "-p", "Run the fixture command."], env=env)
                    observed = json.loads((home / ".vibeguard/state/grok.json").read_text())
                    expected = {"host": "grok", "tool": "run_terminal_command", "tool_use_id": "fixture-call",
                                "outcome": outcome, "exit_code": exit_code}
                    if any(observed.get(key) != value for key, value in expected.items()):
                        raise RuntimeError(f"Unexpected {host} observation: {observed}")
                    if not any(feedback in text for text in server.fixture["tool_results"]):
                        raise RuntimeError(f"Expected {host} tool feedback missing: {server.fixture['tool_results']}")
                    if not canary.exists():
                        raise RuntimeError("Grok executed the denied cleanup in the temporary repository")
                    if (home / ".vibeguard/state/claude.json").exists():
                        raise RuntimeError("Grok was recorded as Claude")
                    print(f"OK: Grok {inspection['grokVersion']} / {host} registration / {outcome}")
                checked([runtime, "uninstall", host, "--home", home])
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runtime", type=Path)
    parser.add_argument("grok", type=Path)
    args = parser.parse_args()
    smoke(args.runtime.resolve(), args.grok.resolve())


if __name__ == "__main__":
    main()

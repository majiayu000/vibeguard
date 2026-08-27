#!/usr/bin/env python3
"""Fail-closed live interception demo for Guard Packs."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Any


class DemoError(ValueError):
    """User-visible live demo failure."""


def _resolve_runtime_and_hook(root: Path) -> tuple[Path, Path, str]:
    source_hook = root / "hooks" / "pre-bash-guard.sh"
    configured_runtime = os.environ.get("VIBEGUARD_RUNTIME")
    if configured_runtime:
        runtime = Path(configured_runtime).expanduser()
        if not runtime.is_file() or not os.access(runtime, os.X_OK):
            raise DemoError(
                f"configured VIBEGUARD_RUNTIME is not executable: {runtime}"
            )
        return runtime, source_hook, "repository hook with configured runtime"

    home = Path.home()
    installed_runtime = home / ".vibeguard" / "installed" / "bin" / "vibeguard-runtime"
    installed_hook = home / ".vibeguard" / "installed" / "hooks" / "pre-bash-guard.sh"
    if (
        installed_runtime.is_file()
        and os.access(installed_runtime, os.X_OK)
        and installed_hook.is_file()
    ):
        return installed_runtime, installed_hook, "installed snapshot"

    for profile in ("release", "debug"):
        runtime = root / "vibeguard-runtime" / "target" / profile / "vibeguard-runtime"
        if runtime.is_file() and os.access(runtime, os.X_OK) and source_hook.is_file():
            return runtime, source_hook, f"repository {profile} build"

    raise DemoError(
        "vibeguard-runtime not found for live demo. Run setup.sh first, or build it with "
        "cargo build --release --manifest-path vibeguard-runtime/Cargo.toml."
    )


def run_live_bash_demo(pack: dict[str, Any], root: Path) -> tuple[str, str, str]:
    """Submit the pack's destructive example to the real hook without executing it."""
    demo = pack["demo"]
    command = str(demo["blocked_example"])
    expected_decision = str(demo["expected_decision"])
    expected_reason = str(demo["expected_reason_contains"])
    if expected_decision != "block":
        raise DemoError("live Bash interception demos must require a block decision")
    runtime, hook, source = _resolve_runtime_and_hook(root)
    payload = json.dumps(
        {
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": command},
        }
    )

    with tempfile.TemporaryDirectory(prefix="vibeguard-live-demo-") as temp_dir:
        sandbox = Path(temp_dir)
        sandbox_home = sandbox / "home"
        sandbox_home.mkdir()
        marker = sandbox_home / "VIBEGUARD_DEMO_MARKER"
        marker.write_text("The guarded command did not run.\n", encoding="utf-8")
        env = os.environ.copy()
        env.update(
            {
                "HOME": str(sandbox_home),
                "VIBEGUARD_RUNTIME": str(runtime),
                "VIBEGUARD_LOG_DIR": str(sandbox / "logs"),
                "VIBEGUARD_CLIENT": "unknown",
                "VIBEGUARD_CLIENT_VARIANT": "safe-bash-demo",
                "VIBEGUARD_CALLER_EVIDENCE": "guard-pack-live-demo",
            }
        )

        try:
            completed = subprocess.run(
                ["bash", str(hook)],
                input=payload,
                cwd=root,
                env=env,
                text=True,
                capture_output=True,
                timeout=10,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            raise DemoError(
                "live demo hook timed out after 10 seconds; command not executed"
            ) from exc
        except OSError as exc:
            raise DemoError(f"cannot start live demo hook {hook}: {exc}") from exc

        if completed.returncode != 0:
            detail = completed.stderr.strip() or completed.stdout.strip() or "no hook output"
            raise DemoError(
                f"live demo hook failed with exit {completed.returncode}; "
                f"command not executed: {detail}"
            )
        try:
            output = json.loads(completed.stdout)
        except json.JSONDecodeError as exc:
            raise DemoError(
                "live demo hook returned malformed JSON; command not executed"
            ) from exc
        if not isinstance(output, dict):
            raise DemoError("live demo hook returned a non-object; command not executed")

        decision = output.get("decision")
        reason = output.get("reason")
        if decision != expected_decision:
            raise DemoError(
                f"live demo failed closed: expected {expected_decision!r}, got "
                f"{decision!r}; command not executed"
            )
        if not isinstance(reason, str) or expected_reason not in reason:
            raise DemoError(
                "live demo failed closed: hook reason did not match the pack contract; "
                "command not executed"
            )
        if not marker.is_file():
            raise DemoError("live demo sandbox marker disappeared unexpectedly")
        return str(decision), reason, source

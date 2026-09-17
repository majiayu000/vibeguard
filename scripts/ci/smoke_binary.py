#!/usr/bin/env python3
"""Exercise a supplied binary and exact installed hook commands in a temporary home."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

def run(binary, *args, payload="", expected=0):
    result = subprocess.run([str(binary), *args], input=payload, text=True, capture_output=True, check=False)
    if result.returncode != expected:
        raise RuntimeError(f"{args}: exit {result.returncode}, expected {expected}: {result.stderr}")
    return result.stdout

def smoke(binary):
    if not run(binary, "--version").startswith("vibeguard-runtime "):
        raise RuntimeError("unexpected binary")
    catalog = json.loads(run(binary, "rules", "--json"))
    if not catalog or not all(r.get("id") and r.get("body") for r in catalog):
        raise RuntimeError("empty or incomplete embedded catalog")
    for host in ("claude", "codex"):
        event = dict(hook_event_name="PreToolUse", cwd="/smoke", tool_name="Bash",
                     tool_input={"command": "git clean -fd"})
        denied = json.loads(run(binary, "hook", host, payload=json.dumps(event)))
        if denied["hookSpecificOutput"]["permissionDecision"] != "deny":
            raise RuntimeError("native denial missing")
        with tempfile.TemporaryDirectory(prefix="vibeguard-smoke-") as temp:
            if os.name != "posix":
                run(binary, "install", host, "--home", temp, expected=2)
                continue
            run(binary, "install", host, "--home", temp)
            config_path = Path(temp) / f".{host}" / ("hooks.json" if host == "codex" else "settings.json")
            config = json.loads(config_path.read_text())
            command = config["hooks"]["PreToolUse"][0]["hooks"][0]["command"]
            # Run the registration, never the destructive proposed tool input.
            result = subprocess.run(["sh", "-c", command], input=json.dumps(event),
                                    text=True, capture_output=True, check=True)
            if json.loads(result.stdout)["hookSpecificOutput"]["permissionDecision"] != "deny":
                raise RuntimeError("installed command did not deny")
            status = json.loads(run(binary, "status", host, "--home", temp))
            if status["last_observation"]["outcome"] != "denied":
                raise RuntimeError("installed hook was not observed")
            run(binary, "uninstall", host, "--home", temp)
            run(binary, "status", host, "--home", temp, expected=1)
    print("OK: supplied binary, catalog, native protocol and temporary installation")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    smoke(args.binary.resolve())

if __name__ == "__main__":
    main()

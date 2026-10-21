#!/usr/bin/env python3
"""Exercise a supplied binary and exact installed hook commands in a temporary home."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

def build_binary(manifest):
    result = subprocess.run(
        ["cargo", "build", "--locked", "--release", "--message-format=json-render-diagnostics",
         "--manifest-path", str(manifest)],
        stdout=subprocess.PIPE, encoding="utf-8", check=True)
    executables = set()
    for line in result.stdout.splitlines():
        message = json.loads(line)
        if (message.get("reason") == "compiler-artifact"
                and message.get("target", {}).get("name") == "vibeguard-runtime"
                and "bin" in message.get("target", {}).get("kind", [])
                and not message.get("profile", {}).get("test")
                and message.get("executable")):
            executables.add(Path(message["executable"]))
    if len(executables) != 1:
        raise RuntimeError("Cargo did not report exactly one vibeguard-runtime executable")
    return executables.pop()

def run(binary, *args, payload="", expected=0):
    result = subprocess.run([str(binary), *args], input=payload, encoding="utf-8", capture_output=True, check=False)
    if result.returncode != expected:
        raise RuntimeError(f"{args}: exit {result.returncode}, expected {expected}: {result.stderr}")
    return result.stdout

def smoke(binary):
    if not run(binary, "--version").startswith("vibeguard-runtime "):
        raise RuntimeError("unexpected binary")
    catalog = json.loads(run(binary, "rules", "--json"))
    if not catalog or not all(r.get("id") and r.get("body") for r in catalog):
        raise RuntimeError("empty or incomplete embedded catalog")
    for host in ("claude", "codex", "grok"):
        event = dict(hook_event_name="PreToolUse", cwd="/smoke", tool_name="Bash",
                     tool_input={"command": "git clean -fd"})
        if host == "grok":
            event = dict(hookEventName="pre_tool_use", cwd="/smoke",
                         toolName="run_terminal_command", toolInput={"command": "git clean -fd"})
        denied = json.loads(run(binary, "hook", host, payload=json.dumps(event)))
        if denied["hookSpecificOutput"]["permissionDecision"] != "deny":
            raise RuntimeError("native denial missing")
        with tempfile.TemporaryDirectory(prefix="vibeguard-smoke-用户 space-") as temp:
            if os.name != "posix" and host != "claude":
                run(binary, "install", host, "--home", temp, expected=2)
                continue
            run(binary, "install", host, "--home", temp)
            config_path = Path(temp) / f".{host}" / ({"codex": "hooks.json", "grok": "hooks/vibeguard.json"}.get(host, "settings.json"))
            config = json.loads(config_path.read_text(encoding="utf-8"))
            handler = config["hooks"]["PreToolUse"][0]["hooks"][0]
            command = ([handler["command"], *handler["args"]] if "args" in handler
                       else ["sh", "-c", handler["command"]])
            # Run the registration, never the destructive proposed tool input.
            result = subprocess.run(command, input=json.dumps(event),
                                    encoding="utf-8", capture_output=True, check=True)
            if json.loads(result.stdout)["hookSpecificOutput"]["permissionDecision"] != "deny":
                raise RuntimeError("installed command did not deny")
            status = json.loads(run(binary, "status", host, "--home", temp))
            if status["last_observation"]["outcome"] != "denied":
                raise RuntimeError("installed hook was not observed")
            if os.name == "nt":
                import ctypes
                from ctypes import wintypes

                get_full_path = ctypes.WinDLL("kernel32", use_last_error=True).GetFullPathNameW
                get_full_path.argtypes = [wintypes.LPCWSTR, wintypes.DWORD,
                                          wintypes.LPWSTR, ctypes.POINTER(wintypes.LPWSTR)]
                get_full_path.restype = wintypes.DWORD
                for raw, resolved, blocked in (
                        ("C:/...", "C:/", True),
                        ("C:/   ", "C:/", True),
                        ("C:/Users/name/...", "C:/Users/name", True),
                        ("C:/Users/name/   ", "C:/Users/name", True),
                        ("C:/Windows/.../../System32", "C:/Windows/System32", True),
                        ("C:/Windows/   /../System32", "C:/Windows/System32", True),
                        ("C:/Users/name/.../../cache", "C:/Users/name/cache", False),
                        ("C:/.../", "C:/.../", False)):
                    buffer = ctypes.create_unicode_buffer(32768)
                    length = get_full_path(raw, len(buffer), buffer, None)
                    if not length or length >= len(buffer):
                        raise RuntimeError(f"GetFullPathNameW failed for {raw!r}")
                    if buffer.value.replace("\\", "/").rstrip("/") != resolved.rstrip("/"):
                        raise RuntimeError(f"GetFullPathNameW({raw!r}) returned {buffer.value!r}")
                    # Resolve names and evaluate JSON only; never execute rm.
                    event["tool_input"]["command"] = f"rm -rf '{raw}'"
                    result = subprocess.run(command, input=json.dumps(event), encoding="utf-8",
                                            capture_output=True, check=True)
                    output = json.loads(result.stdout) if result.stdout.strip() else {}
                    if (output.get("hookSpecificOutput", {}).get("permissionDecision") == "deny") != blocked:
                        raise RuntimeError(f"Windows resolved-path policy mismatch for {raw!r}")
                if "PowerShell and cmd commands are not protected" not in status["coverage"]:
                    raise RuntimeError("Windows coverage boundary missing")
                for proposed, blocked in (("rm -rf /c/Windows", True),
                                          (r"rm -rf 'C:\Users\name'", True),
                                          ("rm -rf C:/Users/name/cache", False),
                                          ("printf hello", False)):
                    event["tool_input"]["command"] = proposed
                    result = subprocess.run(command, input=json.dumps(event), encoding="utf-8",
                                            capture_output=True, check=True)
                    output = json.loads(result.stdout) if result.stdout.strip() else {}
                    if (output.get("hookSpecificOutput", {}).get("permissionDecision") == "deny") != blocked:
                        raise RuntimeError("Windows path recognition mismatch")
            run(binary, "install", host, "--home", temp)
            run(binary, "uninstall", host, "--home", temp)
            run(binary, "status", host, "--home", temp, expected=1)
    print("OK: supplied binary, catalog, native protocol and temporary installation")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path, nargs="?")
    parser.add_argument("--cargo-build", type=Path, metavar="MANIFEST",
                        help="build and smoke the executable reported by Cargo")
    args = parser.parse_args()
    if (args.binary is None) == (args.cargo_build is None):
        parser.error("supply either a binary or --cargo-build MANIFEST")
    binary = build_binary(args.cargo_build) if args.cargo_build is not None else args.binary
    smoke(binary.resolve())

if __name__ == "__main__":
    main()

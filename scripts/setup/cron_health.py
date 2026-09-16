#!/usr/bin/env python3
"""Read-only diagnostics for unmanaged VibeGuard GC jobs in the user crontab."""

import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys


def inspect_entries(crontab: str) -> list[str]:
    findings = []
    for number, line in enumerate(crontab.splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#") or re.match(r"\w+\s*=", line):
            continue
        fields = line.split(None, 1 if line.startswith("@") else 5)
        if len(fields) != (2 if line.startswith("@") else 6):
            continue
        command = fields[-1]
        try:
            lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
            lexer.whitespace_split = True
            words = list(lexer)
        except ValueError:
            if "/scripts/gc/gc-scheduled.sh" in command:
                findings.append(f"[WARN] Unmanaged GC cron line {number}: cannot parse script target; inspect with crontab -l")
            continue
        if not words:
            continue
        interpreted = Path(words[0]).name in {"bash", "sh", "zsh"}
        target = words[1] if interpreted and len(words) > 1 else words[0]
        if not target.endswith("/scripts/gc/gc-scheduled.sh"):
            continue
        prefix = f"Unmanaged GC cron line {number}"
        path = Path(target)
        if not path.is_absolute() or "$" in target or "`" in target:
            findings.append(f"[WARN] {prefix}: script target needs shell resolution; inspect with crontab -l")
        elif not path.is_file() or not os.access(path, os.R_OK):
            findings.append(f"[BROKEN] {prefix}: script missing or unreadable: {target}")
        elif not interpreted and not os.access(path, os.X_OK):
            findings.append(f"[BROKEN] {prefix}: script not executable: {target}")
        else:
            findings.append(f"[WARN] {prefix}: script exists: {target}; cron is user-managed (inspect with crontab -l)")
    return findings


def main() -> int:
    executable = shutil.which("crontab")
    if executable is None:
        return 0
    try:
        result = subprocess.run(
            [executable, "-l"], capture_output=True, text=True, timeout=10,
            env={**os.environ, "LC_ALL": "C"},
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"Cannot read user crontab: {type(exc).__name__}", file=sys.stderr)
        return 1
    if result.returncode:
        if result.returncode == 1 and "no crontab for " in result.stderr.lower():
            return 0
        print(f"Cannot read user crontab (exit {result.returncode}); run crontab -l to diagnose", file=sys.stderr)
        return 1
    for finding in inspect_entries(result.stdout):
        print(finding)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

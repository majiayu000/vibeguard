#!/usr/bin/env python3
"""Compatibility entrypoint for scheduled GC learning digest generation."""

from __future__ import annotations

import os
import runpy
import sys
from pathlib import Path


def main() -> None:
    target = Path(__file__).resolve().parents[1] / "learn" / "analyze.py"
    if len(sys.argv) > 1:
        sys.argv = [str(target), *sys.argv[1:]]
        runpy.run_path(str(target), run_name="__main__")
        return

    log_dir = os.environ["_GC_LOG_DIR"]
    sys.argv = [
        str(target),
        "--scope",
        "global",
        "--scheduled",
        "--format",
        "text",
        "--output",
        os.path.join(log_dir, "learn-digest.jsonl"),
    ]
    if "_GC_LEARNING_WINDOW_DAYS" in os.environ:
        sys.argv.extend(["--learning-window-days", os.environ["_GC_LEARNING_WINDOW_DAYS"]])
    runpy.run_path(str(target), run_name="__main__")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Prune per-project session-metrics.jsonl files for gc-scheduled.sh."""

from __future__ import annotations

import os
from pathlib import Path


def keep_line(line: str, cutoff: str) -> bool:
    if not line.strip():
        return False
    if '"ts"' not in line:
        return True
    idx = line.find('"ts"')
    ts_start = line.find('"', idx + 4) + 1
    ts_val = line[ts_start : ts_start + 10]
    return ts_val >= cutoff[:10]


def main() -> int:
    log_dir = Path(os.environ["_GC_LOG_DIR"])
    cutoff = os.environ["_GC_CUTOFF"]
    cleaned = 0

    for metrics_file in sorted(log_dir.glob("projects/*/session-metrics.jsonl")):
        before_lines = metrics_file.read_text(encoding="utf-8").splitlines(keepends=True)
        kept = [line for line in before_lines if keep_line(line, cutoff)]
        metrics_file.write_text("".join(kept), encoding="utf-8")
        print(f" {len(kept)} reserved items (original {len(before_lines)} items)")
        cleaned += len(before_lines) - len(kept)

    print(f"Clean {cleaned} expired metrics")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

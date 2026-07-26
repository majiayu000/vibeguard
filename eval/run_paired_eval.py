#!/usr/bin/env python3
"""Bootstrap the paired evaluator from a commit-pinned repository snapshot."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]


def _capture_startup_commit(repo_root: Path) -> tuple[str | None, str | None]:
    """Capture HEAD before importing repository-local evaluator modules."""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=repo_root,
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = getattr(exc, "stderr", None) or str(exc)
        return None, detail.strip()
    commit = result.stdout.strip()
    return (commit, None) if commit else (None, "cannot resolve evaluated commit")


def main() -> int:
    startup_commit = None
    startup_commit_error = None
    if "--dry-run" not in sys.argv:
        startup_commit, startup_commit_error = _capture_startup_commit(REPO_ROOT)
    from paired_runner import main as run

    return run(
        startup_commit=startup_commit,
        startup_commit_error=startup_commit_error,
    )


if __name__ == "__main__":
    raise SystemExit(main())
else:
    from paired_runner import *  # noqa: F401,F403
    from paired_runner import _evaluated_provenance_paths  # noqa: F401
